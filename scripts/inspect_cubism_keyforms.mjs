#!/usr/bin/env node

const endpoint = "ws://127.0.0.1:22033";
const minimumKeyforms = new Map([
  ["ParamAngleX", 3], ["ParamAngleY", 3], ["ParamAngleZ", 3],
  ["ParamBodyAngleX", 3], ["ParamEyeBallX", 3], ["ParamEyeBallY", 3],
  ["ParamEyeLOpen", 2], ["ParamEyeROpen", 2], ["ParamMouthOpenY", 2],
  ["ParamBreath", 2],
  ["ParamBodyAngleY", 3], ["ParamBodyAngleZ", 3], ["ParamBodyY", 3],
  ["ParamTail", 3], ["ParamEarL", 3], ["ParamEarR", 3],
  ["ParamLegFrontL", 3], ["ParamPawFrontL", 3],
  ["ParamLegFrontR", 3], ["ParamPawFrontR", 3],
  ["ParamLegHindL", 3], ["ParamPawHindL", 3],
  ["ParamLegHindR", 3], ["ParamPawHindR", 3],
]);

function connect() {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(endpoint);
    const timeout = setTimeout(() => {
      socket.close();
      reject(new Error("Cubism Editor External Application Integration is not enabled"));
    }, 5_000);
    socket.addEventListener("open", () => {
      clearTimeout(timeout);
      resolve(socket);
    });
    socket.addEventListener("error", () => {
      clearTimeout(timeout);
      reject(new Error("Cannot connect to Cubism Editor at ws://127.0.0.1:22033"));
    });
  });
}

function client(socket) {
  const pending = new Map();
  socket.addEventListener("message", (event) => {
    let message;
    try {
      message = JSON.parse(String(event.data));
    } catch {
      return;
    }
    const requestId = message.RequestId;
    if (!requestId || !pending.has(requestId)) return;
    const { resolve, reject, timeout } = pending.get(requestId);
    pending.delete(requestId);
    clearTimeout(timeout);
    if (message.Type === "Error" || message.Error) {
      reject(new Error(JSON.stringify(message.Error ?? message)));
    } else {
      resolve(message.Data ?? message);
    }
  });

  return (method, data = {}, timeoutMilliseconds = 30_000) =>
    new Promise((resolve, reject) => {
      const requestId = crypto.randomUUID();
      const timeout = setTimeout(() => {
        pending.delete(requestId);
        reject(new Error(`${method} timed out`));
      }, timeoutMilliseconds);
      pending.set(requestId, { resolve, reject, timeout });
      socket.send(JSON.stringify({
        Version: "1.0.1",
        Timestamp: Date.now(),
        RequestId: requestId,
        Type: "Request",
        Method: method,
        Data: data,
      }));
    });
}

async function main() {
  const socket = await connect();
  const request = client(socket);
  try {
    await request("RegisterPlugin", {
      Name: "RealPet Template Inspector",
      Path: new URL(import.meta.url).pathname,
    }, 60_000);

    let approved = false;
    for (let attempt = 0; attempt < 30; attempt += 1) {
      const response = await request("GetIsApproval");
      approved = response.Result === true;
      if (approved) break;
      await new Promise((resolve) => setTimeout(resolve, 1_000));
    }
    if (!approved) throw new Error("RealPet Template Inspector was not approved in Editor");

    const current = await request("GetCurrentModelUID");
    const modelUID = current.ModelUID;
    if (!modelUID) throw new Error("No current Cubism model is open");
    const result = await request("GetParameters", { ModelUID: modelUID });
    const parameters = Array.isArray(result.Parameters) ? result.Parameters : [];
    const byId = new Map(parameters.map((parameter) => [parameter.Id, parameter]));
    const checks = [...minimumKeyforms].map(([id, minimum]) => {
      const parameter = byId.get(id);
      const keyforms = Array.isArray(parameter?.Keyform) ? parameter.Keyform : [];
      return {
        id,
        minimum,
        values: keyforms.map((keyform) => keyform.Value),
        valid: keyforms.length >= minimum,
      };
    });
    const report = {
      modelUID,
      parameterCount: parameters.length,
      contract: "quadruped-v2",
      valid: checks.every((check) => check.valid),
      checks,
    };
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    if (!report.valid) process.exitCode = 1;
  } finally {
    socket.close();
  }
}

main().catch((error) => {
  process.stderr.write(`Cubism inspection failed: ${error.message}\n`);
  process.exitCode = 1;
});
