import { createClient } from "npm:@supabase/supabase-js@2";

const MINIMAX_CREATE_URL = "https://api.minimaxi.com/v2/video_generation";
const MINIMAX_QUERY_URL = "https://api.minimaxi.com/v2/query/video_generation";
const REFERENCE_BUCKET = "pet-reference-images";
const SIGNED_URL_LIFETIME_SECONDS = 60 * 60;
const ACTIVE_JOB_STALE_AFTER_MS = 10 * 60 * 1000;
const ACTION_KINDS = new Set([
  "head_follow",
  "lie_down",
  "paw",
  "eat",
  "cry",
  "angry_stomp",
  "roll",
  "stretch",
  "sleep_snore",
  "wave",
  "jump_cheer",
  "cuddle",
]);

type ActionKind =
  | "head_follow"
  | "lie_down"
  | "paw"
  | "eat"
  | "cry"
  | "angry_stomp"
  | "roll"
  | "stretch"
  | "sleep_snore"
  | "wave"
  | "jump_cheer"
  | "cuddle";

type ProviderStatus =
  | "submitting"
  | "queued"
  | "running"
  | "succeeded"
  | "failed"
  | "expired";

type ProviderResolution = "2K";
const H3_NATIVE_RESOLUTION: ProviderResolution = "2K";

interface MotionVideoJob {
  id: string;
  user_id: string;
  pet_id: string;
  action_kind: ActionKind;
  duration_seconds: number;
  provider_model: string;
  provider_resolution: ProviderResolution;
  provider_cost_cents: number | null;
  provider_task_id: string | null;
  provider_status: ProviderStatus;
  error_message: string | null;
  result_url: string | null;
  created_at: string;
  updated_at: string;
}

interface CreateRequest {
  operation: "create";
  petId: string;
  actionKind: ActionKind;
  durationSeconds: number;
  resolution: ProviderResolution;
}

interface StatusRequest {
  operation: "status";
  jobId: string;
}

type FunctionRequest = CreateRequest | StatusRequest;

class FunctionError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }
}

Deno.serve(async (request) => {
  try {
    if (request.method !== "POST") {
      throw new FunctionError(405, "Only POST is supported");
    }

    const authorization = request.headers.get("Authorization")?.trim();
    if (!authorization?.startsWith("Bearer ")) {
      throw new FunctionError(401, "A Supabase user session is required");
    }

    const userClient = createUserClient(authorization);
    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData.user) {
      throw new FunctionError(401, "The Supabase user session is invalid");
    }

    const body = parseRequest(await request.json());
    if (body.operation === "create") {
      return json(await createJob(body, authData.user.id, userClient));
    }
    return json(await refreshJob(body, authData.user.id));
  } catch (error) {
    if (error instanceof FunctionError) {
      return json({ error: error.message }, error.status);
    }
    console.error("minimax-video unexpected error", error);
    return json({ error: "Video generation service is temporarily unavailable" }, 500);
  }
});

function createUserClient(authorization: string) {
  return createClient(supabaseURL(), publishableKey(), {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
      detectSessionInUrl: false,
    },
    global: { headers: { Authorization: authorization } },
  });
}

function createAdminClient() {
  return createClient(supabaseURL(), secretKey(), {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
      detectSessionInUrl: false,
    },
  });
}

async function createJob(
  input: CreateRequest,
  userID: string,
  userClient: ReturnType<typeof createUserClient>,
) {
  const admin = createAdminClient();
  await failStaleSubmission(admin, userID, input.petId, input.actionKind);

  const existing = await activeJob(admin, userID, input.petId, input.actionKind);
  if (existing) {
    return jobResponse(existing);
  }

  const { data: created, error: insertError } = await admin
    .from("realpet_motion_video_jobs")
    .insert({
      user_id: userID,
      pet_id: input.petId,
      action_kind: input.actionKind,
      duration_seconds: input.durationSeconds,
      provider_model: "MiniMax-H3",
      provider_resolution: input.resolution,
      provider_status: "submitting",
    })
    .select("*")
    .single();

  if (insertError) {
    // The partial unique index serializes duplicate button presses. Return the
    // already-submitting job instead of charging for another provider task.
    if (insertError.code === "23505") {
      const concurrentJob = await activeJob(
        admin, userID, input.petId, input.actionKind,
      );
      if (concurrentJob) return jobResponse(concurrentJob);
    }
    throw new FunctionError(500, "Unable to create the video job");
  }

  const job = created as MotionVideoJob;
  try {
    const referenceURLs = await signedReferenceURLs(userClient, userID, input.petId);
    const providerResponse = await submitToMiniMax({
      prompt: promptFor(input.actionKind, referenceURLs.length),
      referenceURLs,
      durationSeconds: input.durationSeconds,
      resolution: input.resolution,
    });

    const updated = await updateJob(admin, job.id, userID, {
      provider_task_id: providerResponse.task_id,
      provider_status: "queued",
      error_message: null,
    });
    return jobResponse(updated);
  } catch (error) {
    const message = clientSafeError(error);
    await updateJob(admin, job.id, userID, {
      provider_status: "failed",
      error_message: message,
    });
    throw error;
  }
}

async function refreshJob(input: StatusRequest, userID: string) {
  const admin = createAdminClient();
  const job = await ownedJob(admin, input.jobId, userID);
  if (["succeeded", "failed", "expired"].includes(job.provider_status)) {
    return jobResponse(job);
  }
  if (!job.provider_task_id) {
    return jobResponse(job);
  }

  const providerTask = await queryMiniMax(job.provider_task_id);
  const providerStatus = parseProviderStatus(providerTask.status);
  const resultURL = providerTask.content?.url;
  const providerError = providerTask.error?.message;
  const updated = await updateJob(admin, job.id, userID, {
    provider_status: providerStatus,
    result_url: providerStatus === "succeeded" ? resultURL ?? null : null,
    provider_cost_cents: providerStatus === "succeeded"
      ? miniMaxCostCents(job.duration_seconds)
      : null,
    error_message: providerStatus === "failed" || providerStatus === "expired"
      ? truncate(providerError ?? `MiniMax task ${providerTask.status}`, 500)
      : null,
  });

  if (providerStatus === "succeeded" && !updated.result_url) {
    await updateJob(admin, job.id, userID, {
      provider_status: "failed",
      provider_cost_cents: null,
      error_message: "MiniMax completed without a video URL",
    });
    throw new FunctionError(502, "MiniMax completed without a downloadable video");
  }
  return jobResponse(updated);
}

async function signedReferenceURLs(
  userClient: ReturnType<typeof createUserClient>,
  userID: string,
  petID: string,
): Promise<string[]> {
  const prefix = `${userID}/${petID}/references`;
  const { data: listed, error: listError } = await userClient.storage
    .from(REFERENCE_BUCKET)
    .list(prefix, {
      limit: 16,
      sortBy: { column: "created_at", order: "asc" },
    });
  if (listError) {
    throw new FunctionError(502, "Unable to read the pet reference gallery");
  }

  const objectPaths = (listed ?? [])
    .map((entry) => makeOwnedReferencePath(prefix, entry.name))
    .filter((path): path is string => path !== null)
    .slice(0, 4);
  if (objectPaths.length === 0) {
    throw new FunctionError(422, "Upload one to four pet photos before generating a video");
  }

  const { data: signed, error: signError } = await userClient.storage
    .from(REFERENCE_BUCKET)
    .createSignedUrls(objectPaths, SIGNED_URL_LIFETIME_SECONDS);
  if (signError || !signed || signed.length !== objectPaths.length) {
    throw new FunctionError(502, "Unable to prepare the pet reference photos");
  }

  const urls = signed.map((entry) => absoluteSignedURL(entry.signedUrl));
  if (urls.some((url) => url === null)) {
    throw new FunctionError(502, "Unable to prepare the pet reference photos");
  }
  return urls as string[];
}

function makeOwnedReferencePath(prefix: string, rawName: string): string | null {
  const name = rawName.replace(/^\/+/, "");
  if (!name || name.includes("..") || name.includes("\\")) return null;
  const path = name.startsWith(`${prefix}/`) ? name : `${prefix}/${name}`;
  if (!path.startsWith(`${prefix}/`) || path.split("/").length !== 4) return null;
  return path;
}

function absoluteSignedURL(value: string | null | undefined): string | null {
  if (!value) return null;
  try {
    return new URL(value, supabaseURL()).toString();
  } catch {
    return null;
  }
}

async function submitToMiniMax(input: {
  prompt: string;
  referenceURLs: string[];
  durationSeconds: number;
  resolution: ProviderResolution;
}): Promise<{ task_id: string }> {
  const content = [
    { type: "text", text: input.prompt },
    ...input.referenceURLs.map((url) => ({
      type: "image_url",
      image_url: { url },
      role: "reference_image",
    })),
  ];
  const response = await fetch(MINIMAX_CREATE_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${miniMaxAPIKey()}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "MiniMax-H3",
      content,
      resolution: input.resolution,
      duration: input.durationSeconds,
      ratio: "adaptive",
      aigc_watermark: false,
    }),
  });
  const payload = await response.json().catch(() => null);
  if (!response.ok) {
    throw new FunctionError(
      response.status === 429 ? 429 : 502,
      `MiniMax request failed: ${providerErrorMessage(payload)}`,
    );
  }
  if (!isRecord(payload) || typeof payload.task_id !== "string" || !payload.task_id) {
    throw new FunctionError(502, "MiniMax returned no video task ID");
  }
  return { task_id: payload.task_id };
}

async function queryMiniMax(taskID: string): Promise<MiniMaxTask> {
  const response = await fetch(
    `${MINIMAX_QUERY_URL}/${encodeURIComponent(taskID)}`,
    { headers: { Authorization: `Bearer ${miniMaxAPIKey()}` } },
  );
  const payload = await response.json().catch(() => null);
  if (!response.ok) {
    throw new FunctionError(
      response.status === 429 ? 429 : 502,
      `MiniMax query failed: ${providerErrorMessage(payload)}`,
    );
  }
  if (!isRecord(payload) || !isRecord(payload.task) || typeof payload.task.status !== "string") {
    throw new FunctionError(502, "MiniMax returned an invalid task status");
  }
  return {
    status: payload.task.status,
    content: isRecord(payload.task.content) && typeof payload.task.content.url === "string"
      ? { url: payload.task.content.url }
      : undefined,
    error: isRecord(payload.task.error) && typeof payload.task.error.message === "string"
      ? { message: payload.task.error.message }
      : undefined,
  };
}

interface MiniMaxTask {
  status: string;
  content?: { url: string };
  error?: { message: string };
}

function parseProviderStatus(value: string): ProviderStatus {
  switch (value.toLowerCase()) {
    case "queued":
      return "queued";
    case "running":
      return "running";
    case "succeeded":
      return "succeeded";
    case "failed":
    case "cancelled":
      return "failed";
    case "expired":
      return "expired";
    default:
      throw new FunctionError(502, "MiniMax returned an unknown task status");
  }
}

async function activeJob(
  admin: ReturnType<typeof createAdminClient>,
  userID: string,
  petID: string,
  actionKind: ActionKind,
): Promise<MotionVideoJob | null> {
  const { data, error } = await admin
    .from("realpet_motion_video_jobs")
    .select("*")
    .eq("user_id", userID)
    .eq("pet_id", petID)
    .eq("action_kind", actionKind)
    .in("provider_status", ["submitting", "queued", "running"])
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw new FunctionError(500, "Unable to read existing video jobs");
  return data as MotionVideoJob | null;
}

async function ownedJob(
  admin: ReturnType<typeof createAdminClient>,
  jobID: string,
  userID: string,
): Promise<MotionVideoJob> {
  const { data, error } = await admin
    .from("realpet_motion_video_jobs")
    .select("*")
    .eq("id", jobID)
    .eq("user_id", userID)
    .maybeSingle();
  if (error) throw new FunctionError(500, "Unable to read the video job");
  if (!data) throw new FunctionError(404, "Video job not found");
  return data as MotionVideoJob;
}

async function updateJob(
  admin: ReturnType<typeof createAdminClient>,
  jobID: string,
  userID: string,
  patch: Partial<Pick<
    MotionVideoJob,
    "provider_task_id" | "provider_status" | "error_message" | "result_url"
      | "provider_cost_cents"
  >>,
): Promise<MotionVideoJob> {
  const { data, error } = await admin
    .from("realpet_motion_video_jobs")
    .update(patch)
    .eq("id", jobID)
    .eq("user_id", userID)
    .select("*")
    .single();
  if (error || !data) throw new FunctionError(500, "Unable to update the video job");
  return data as MotionVideoJob;
}

async function failStaleSubmission(
  admin: ReturnType<typeof createAdminClient>,
  userID: string,
  petID: string,
  actionKind: ActionKind,
) {
  const cutoff = new Date(Date.now() - ACTIVE_JOB_STALE_AFTER_MS).toISOString();
  await admin
    .from("realpet_motion_video_jobs")
    .update({
      provider_status: "failed",
      error_message: "The previous submission timed out before MiniMax accepted it",
    })
    .eq("user_id", userID)
    .eq("pet_id", petID)
    .eq("action_kind", actionKind)
    .eq("provider_status", "submitting")
    .is("provider_task_id", null)
    .lt("created_at", cutoff);
}

function parseRequest(value: unknown): FunctionRequest {
  if (!isRecord(value) || typeof value.operation !== "string") {
    throw new FunctionError(400, "Invalid request body");
  }
  if (value.operation === "create") {
    if (!isUUID(value.petId) || !isActionKind(value.actionKind) || !isDuration(value.durationSeconds)) {
      throw new FunctionError(400, "Invalid create request");
    }
    if (value.resolution !== undefined && value.resolution !== H3_NATIVE_RESOLUTION) {
      throw new FunctionError(400, "Unsupported MiniMax H3 resolution");
    }
    return {
      operation: "create",
      petId: value.petId,
      actionKind: value.actionKind,
      durationSeconds: value.durationSeconds,
      // Keep the current desktop app compatible while preserving the server's
      // explicit provider contract for newer clients.
      resolution: H3_NATIVE_RESOLUTION,
    };
  }
  if (value.operation === "status") {
    if (!isUUID(value.jobId)) throw new FunctionError(400, "Invalid status request");
    return { operation: "status", jobId: value.jobId };
  }
  throw new FunctionError(400, "Unsupported operation");
}

function isUUID(value: unknown): value is string {
  return typeof value === "string"
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function isActionKind(value: unknown): value is ActionKind {
  return typeof value === "string" && ACTION_KINDS.has(value);
}

function isDuration(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 4 && value <= 15;
}

function promptFor(action: ActionKind, referenceCount: number): string {
  const identity = referenceCount === 1
    ? "仅使用这 1 张宠物素材图锁定外观，必须始终是同一只宠物。"
    : referenceCount === 2
    ? "综合这 2 张宠物素材图交叉校验毛色、花纹、脸型、眼睛、耳朵和体型，必须始终是同一只宠物。"
    : referenceCount === 3
    ? "综合这 3 张宠物素材图完整锁定毛色、花纹、脸型、眼睛、耳朵和体型，必须始终是同一只宠物。"
    : "综合全部 4 张宠物素材图严格锁定毛色、花纹、脸型、眼睛、耳朵和体型，必须始终是同一只宠物。";
  return `${identity} ${actionMotion(action)}`;
}

function actionMotion(action: ActionKind): string {
  const motion: Record<ActionKind, string> = {
    head_follow: "主体安静端坐正对镜头，身体、四肢和尾巴完全静止；只有头部和双眼极度平滑地顺时针依次注视上方、右侧、下方、左侧、上方并回到正前方。固定机位，无身体转动、移动或镜头运动。",
    lie_down: "角色正对镜头自然站立，缓慢躺倒露出放松撒娇姿态，四肢自然收拢，短暂停留后平稳回到初始站姿。固定机位，动作完整可见。",
    paw: "角色正对镜头自然站立，仅抬起一只前爪在身前连续轻轻扒拉两次，头部专注看着爪子，随后回到初始站姿。固定机位。",
    eat: "角色正对镜头自然站立，抬头张嘴做出吞下一小块食物的自然动作，轻微咀嚼后闭嘴并回到初始站姿。固定机位。",
    cry: "角色坐在地上，双手（或前肢）揉眼睛，身体微微抽泣颤抖，头部低垂，表现出非常委屈、伤心哭泣的样子，动作惹人怜爱",
    angry_stomp: "角色双手叉腰（或前肢撑地），气呼呼地看着镜头，连续用力跺脚，身体微微前倾，头部快速晃动，表现出非常生气的状态",
    roll: "角色躺在地上，左右来回连续翻滚，四肢在空中挥舞，动作流畅自然，带有强烈的趣味性和物理惯性",
    stretch: "角色站在原地，双手（或前肢）用力向上伸展，身体向后拉伸拉长，然后伴随着深呼吸慢慢放松恢复原状，动作慵懒舒适",
    sleep_snore: "角色趴在地上闭着眼睛熟睡，身体随着呼吸有节奏地平缓起伏，头部轻轻点地，呈现出香甜睡觉打呼噜的姿态",
    wave: "角色面朝镜头站立，面带微笑，举起一只手（或前肢）左右欢快地摇晃挥舞，做出打招呼或说再见的连贯动作",
    jump_cheer: "角色非常激动，原地连续向上蹦跳，双手（或前肢）高高举起欢呼，落地时有自然的缓冲，动作充满活力与开心",
    cuddle: "角色身体向前倾靠，双手（或前肢）向前伸出做拥抱状，头部微微上仰看着镜头，左右轻轻扭动身体，表现出撒娇的姿态",
  };
  return motion[action];
}

function jobResponse(job: MotionVideoJob) {
  return {
    jobId: job.id,
    status: job.provider_status,
    durationSeconds: job.duration_seconds,
    providerModel: job.provider_model,
    providerResolution: job.provider_resolution,
    providerCostCents: job.provider_status === "succeeded"
      ? job.provider_cost_cents
      : null,
    resultUrl: job.provider_status === "succeeded" ? job.result_url : null,
    error: job.provider_status === "failed" || job.provider_status === "expired"
      ? job.error_message
      : null,
  };
}

function supabaseURL(): string {
  return requiredEnvironment("SUPABASE_URL");
}

function miniMaxAPIKey(): string {
    return requiredEnvironment("MINIMAX_API_KEY");
}

function miniMaxCostCents(seconds: number): number | null {
  const raw = Deno.env.get("MINIMAX_COST_CENTS_PER_SECOND")?.trim();
  if (!raw) return null;
  const rate = Number(raw);
  if (!Number.isFinite(rate) || rate < 0) {
    throw new FunctionError(500, "MINIMAX_COST_CENTS_PER_SECOND is invalid");
  }
  return Math.round(rate * seconds);
}

function publishableKey(): string {
  const modern = keyFromDictionary("SUPABASE_PUBLISHABLE_KEYS");
  return modern ?? requiredEnvironment("SUPABASE_ANON_KEY");
}

function secretKey(): string {
  const modern = keyFromDictionary("SUPABASE_SECRET_KEYS");
  return modern ?? requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY");
}

function keyFromDictionary(name: string): string | null {
  const value = Deno.env.get(name);
  if (!value) return null;
  try {
    const parsed = JSON.parse(value) as Record<string, unknown>;
    const candidate = parsed.default ?? Object.values(parsed)[0];
    return typeof candidate === "string" && candidate ? candidate : null;
  } catch {
    return null;
  }
}

function requiredEnvironment(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new FunctionError(500, `Missing server configuration: ${name}`);
  return value;
}

function providerErrorMessage(payload: unknown): string {
  if (isRecord(payload)) {
    if (isRecord(payload.error) && typeof payload.error.message === "string") {
      return truncate(payload.error.message, 500);
    }
    if (typeof payload.message === "string") return truncate(payload.message, 500);
  }
  return "unknown provider error";
}

function clientSafeError(error: unknown): string {
  if (error instanceof FunctionError) return truncate(error.message, 500);
  return "Unable to submit the MiniMax video task";
}

function truncate(value: string, limit: number): string {
  return value.length <= limit ? value : `${value.slice(0, limit - 1)}…`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}
