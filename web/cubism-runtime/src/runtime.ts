import { CubismFramework, Option } from '@framework/live2dcubismframework';
import { CubismModelSettingJson } from '@framework/cubismmodelsettingjson';
import { CubismMoc } from '@framework/model/cubismmoc';
import { CubismModel } from '@framework/model/cubismmodel';
import { CubismModelMatrix } from '@framework/math/cubismmodelmatrix';
import { CubismMatrix44 } from '@framework/math/cubismmatrix44';
import { CubismRenderer_WebGL } from '@framework/rendering/cubismrenderer_webgl';
import { CubismWebGLOffscreenManager } from '@framework/rendering/cubismoffscreenmanager';
import { ACubismMotion } from '@framework/motion/acubismmotion';
import { CubismMotion } from '@framework/motion/cubismmotion';
import { CubismMotionManager } from '@framework/motion/cubismmotionmanager';

export interface BootOptions {
  canvas: HTMLCanvasElement;
  modelUrl: string;
  templateUrl: string;
  shaderPath: string;
  onReady?: () => void;
  onError?: (message: string) => void;
}

type SemanticAction = 'idle' | 'walk' | 'react' | 'shake_head' | 'play';

export interface ProceduralAction {
  action: SemanticAction;
  duration: number;
  intensity: number;
  clip?: ParameterClip;
}

interface ParameterFrame {
  time: number;
  parameters: Record<string, number>;
}

interface ParameterClip {
  duration: number;
  loop: boolean;
  frames: ParameterFrame[];
}

interface ActiveAction extends ProceduralAction {
  startedAt: number;
}

interface TemplateDescriptor {
  id: string;
  contract?: string;
  parameters?: string[];
  slots: Record<string, unknown>;
  partDrawables: Record<string, string>;
  semanticMotions: Partial<Record<SemanticAction, string>>;
}

const QUADRUPED_V2_PARAMETERS = [
  'ParamAngleX', 'ParamAngleY', 'ParamAngleZ', 'ParamBodyAngleX',
  'ParamEyeBallX', 'ParamEyeBallY', 'ParamEyeLOpen', 'ParamEyeROpen',
  'ParamMouthOpenY', 'ParamBreath', 'ParamBodyAngleY', 'ParamBodyAngleZ',
  'ParamBodyY', 'ParamTail', 'ParamLegFrontL', 'ParamPawFrontL',
  'ParamLegFrontR', 'ParamPawFrontR', 'ParamLegHindL', 'ParamPawHindL',
  'ParamLegHindR', 'ParamPawHindR', 'ParamEarL', 'ParamEarR'
] as const;

class Runtime {
  private canvas: HTMLCanvasElement | null = null;
  private gl: WebGL2RenderingContext | null = null;
  private model: CubismModel | null = null;
  private moc: CubismMoc | null = null;
  private renderer: CubismRenderer_WebGL | null = null;
  private modelMatrix: CubismModelMatrix | null = null;
  private shaderPath = '';
  private targetParameters = new Map<string, number>();
  private currentParameters = new Map<string, number>();
  private paused = false;
  private lastFrameAt = 0;
  private animationFrame = 0;
  private activeAction: ActiveAction | null = null;
  private motionManager: CubismMotionManager | null = null;
  private motions = new Map<string, CubismMotion[]>();
  private semanticMotions: TemplateDescriptor['semanticMotions'] = {};
  private motionCursor = new Map<string, number>();
  private nativeMotionSemantic: ProceduralAction['action'] | null = null;
  private generatedIdle: ParameterClip | null = null;

  async boot(options: BootOptions): Promise<void> {
    this.release();
    this.canvas = options.canvas;
    this.shaderPath = options.shaderPath;
    const gl = options.canvas.getContext('webgl2', {
      alpha: true,
      antialias: true,
      premultipliedAlpha: true
    });
    if (!gl) throw new Error('WebGL2 is unavailable');
    this.gl = gl;

    try {
      this.startFramework();
      const settingsResponse = await fetch(options.modelUrl);
      if (!settingsResponse.ok) throw new Error('model3.json could not be loaded');
      const settingsBytes = await settingsResponse.arrayBuffer();
      const settings = new CubismModelSettingJson(
        settingsBytes, settingsBytes.byteLength);
      const modelBase = new URL('.', options.modelUrl).toString();

      const mocResponse = await fetch(new URL(
        settings.getModelFileName(), modelBase));
      if (!mocResponse.ok) throw new Error('moc3 could not be loaded');
      const mocBytes = await mocResponse.arrayBuffer();
      this.moc = CubismMoc.create(mocBytes, true);
      if (!this.moc) throw new Error('moc3 consistency validation failed');
      this.model = this.moc.createModel();
      if (!this.model) throw new Error('Cubism model creation failed');
      this.model.saveParameters();
      this.motionManager = new CubismMotionManager();

      await this.loadTemplateDescriptor(options.templateUrl);
      await this.loadMotions(settings, modelBase);

      this.modelMatrix = new CubismModelMatrix(
        this.model.getCanvasWidth(), this.model.getCanvasHeight());
      this.renderer = new CubismRenderer_WebGL(
        options.canvas.width, options.canvas.height);
      this.renderer.initialize(this.model);
      this.renderer.startUp(gl);
      this.renderer.setIsPremultipliedAlpha(true);
      this.renderer.loadShaders(this.shaderPath);

      const textureTasks: Promise<void>[] = [];
      for (let index = 0; index < settings.getTextureCount(); index++) {
        textureTasks.push(this.loadTexture(
          index, new URL(settings.getTextureFileName(index), modelBase).toString()));
      }
      await Promise.all(textureTasks);
      this.resize();
      this.lastFrameAt = performance.now();
      this.animationFrame = requestAnimationFrame(this.drawFrame);
      this.startSemanticMotion('idle');
      options.onReady?.();
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      options.onError?.(message);
      this.release();
      throw error;
    }
  }

  setParameters(parameters: Record<string, number>): void {
    for (const [identifier, value] of Object.entries(parameters)) {
      if (Number.isFinite(value)) this.targetParameters.set(identifier, value);
    }
  }

  setPaused(paused: boolean): void {
    this.paused = paused;
  }

  triggerAction(action: ProceduralAction): void {
    if (!['idle', 'walk', 'react', 'shake_head', 'play'].includes(action.action)) return;
    const clip = this.validatedClip(action.clip);
    if (action.action === 'idle') {
      if (clip) this.generatedIdle = clip;
      this.activeAction = null;
      if (!this.startSemanticMotion('idle')) this.activateGeneratedIdle();
      return;
    }
    if (this.startSemanticMotion(action.action)) {
      this.activeAction = null;
    } else if (clip) {
      this.activateGenerated(action, clip);
    }
  }

  pixelProbe(): number {
    if (!this.gl || !this.canvas) return 0;
    const width = Math.min(16, this.canvas.width);
    const height = Math.min(16, this.canvas.height);
    const pixels = new Uint8Array(width * height * 4);
    this.gl.readPixels(
      Math.max(0, Math.floor((this.canvas.width - width) / 2)),
      Math.max(0, Math.floor((this.canvas.height - height) / 2)),
      width, height, this.gl.RGBA, this.gl.UNSIGNED_BYTE, pixels);
    return pixels.reduce((sum, value) => (sum + value) >>> 0, 0);
  }

  release(): void {
    if (this.animationFrame) cancelAnimationFrame(this.animationFrame);
    this.animationFrame = 0;
    this.renderer?.release();
    this.renderer = null;
    if (this.moc && this.model) this.moc.deleteModel(this.model);
    this.model = null;
    this.moc?.release();
    this.moc = null;
    this.modelMatrix = null;
    this.motionManager?.stopAllMotions();
    this.motionManager?.release();
    this.motionManager = null;
    for (const group of this.motions.values()) {
      for (const motion of group) ACubismMotion.delete(motion);
    }
    this.motions.clear();
    this.motionCursor.clear();
    this.nativeMotionSemantic = null;
    this.targetParameters.clear();
    this.currentParameters.clear();
    this.activeAction = null;
    this.generatedIdle = null;
    this.canvas = null;
    this.gl = null;
  }

  private startFramework(): void {
    if (CubismFramework.isStarted()) return;
    const option = new Option();
    option.logFunction = (message: string) => console.debug(message);
    CubismFramework.startUp(option);
    CubismFramework.initialize();
  }

  private async loadTexture(index: number, url: string): Promise<void> {
    if (!this.gl || !this.renderer) throw new Error('renderer is not ready');
    const response = await fetch(url);
    if (!response.ok) throw new Error(`texture could not be loaded: ${index}`);
    const bitmap = await createImageBitmap(await response.blob());
    const texture = this.gl.createTexture();
    if (!texture) throw new Error(`texture allocation failed: ${index}`);
    this.gl.bindTexture(this.gl.TEXTURE_2D, texture);
    this.gl.pixelStorei(this.gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, 1);
    this.gl.texImage2D(
      this.gl.TEXTURE_2D, 0, this.gl.RGBA,
      this.gl.RGBA, this.gl.UNSIGNED_BYTE, bitmap);
    this.gl.texParameteri(
      this.gl.TEXTURE_2D, this.gl.TEXTURE_MIN_FILTER, this.gl.LINEAR_MIPMAP_LINEAR);
    this.gl.texParameteri(
      this.gl.TEXTURE_2D, this.gl.TEXTURE_MAG_FILTER, this.gl.LINEAR);
    this.gl.generateMipmap(this.gl.TEXTURE_2D);
    this.gl.bindTexture(this.gl.TEXTURE_2D, null);
    bitmap.close();
    this.renderer.bindTexture(index, texture);
  }

  private async loadTemplateDescriptor(url: string): Promise<void> {
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error('RealPet Cubism template descriptor is missing');
    }
    const descriptor = await response.json() as Partial<TemplateDescriptor>;
    const motions = descriptor.semanticMotions ?? {};
    const allowed = ['idle', 'walk', 'react', 'shake_head', 'play'];
    if (Object.entries(motions).some(
      ([key, value]) => !allowed.includes(key)
        || typeof value !== 'string' || value.length === 0)) {
      throw new Error('RealPet Cubism semantic motion map is invalid');
    }
    this.validateIndependentParts(descriptor);
    this.semanticMotions = motions as TemplateDescriptor['semanticMotions'];
  }

  private validateIndependentParts(
    descriptor: Partial<TemplateDescriptor>
  ): void {
    if (descriptor.contract !== 'quadruped-v2') return;
    if (!this.model || !descriptor.slots || !descriptor.partDrawables) {
      throw new Error('quadruped-v2 independent-part map is missing');
    }
    if (!Array.isArray(descriptor.parameters)
      || QUADRUPED_V2_PARAMETERS.some(
        parameter => !descriptor.parameters?.includes(parameter))) {
      throw new Error('quadruped-v2 parameter contract is incomplete');
    }
    const slotNames = Object.keys(descriptor.slots).sort();
    const mappings = Object.entries(descriptor.partDrawables);
    const mappedNames = mappings.map(([name]) => name).sort();
    const drawableIds = mappings.map(([, drawable]) => drawable);
    if (slotNames.length !== 20
      || slotNames.some((name, index) => name !== mappedNames[index])
      || drawableIds.some(id => typeof id !== 'string' || id.length === 0)
      || new Set(drawableIds).size !== drawableIds.length) {
      throw new Error('quadruped-v2 parts must map to 20 unique drawables');
    }
    for (const [part, drawable] of mappings) {
      const id = CubismFramework.getIdManager().getId(drawable);
      if (this.model.getDrawableIndex(id) < 0) {
        throw new Error(`quadruped-v2 drawable is unavailable: ${part}`);
      }
    }
    for (const parameter of QUADRUPED_V2_PARAMETERS) {
      const id = CubismFramework.getIdManager().getId(parameter);
      if (this.model.getParameterIndex(id) < 0) {
        throw new Error(`quadruped-v2 parameter is unavailable: ${parameter}`);
      }
    }
  }

  private async loadMotions(
    settings: CubismModelSettingJson,
    modelBase: string
  ): Promise<void> {
    const tasks: Promise<void>[] = [];
    for (let groupIndex = 0;
      groupIndex < settings.getMotionGroupCount(); groupIndex++) {
      const group = settings.getMotionGroupName(groupIndex);
      const loaded: CubismMotion[] = [];
      this.motions.set(group, loaded);
      for (let index = 0; index < settings.getMotionCount(group); index++) {
        tasks.push((async () => {
          const response = await fetch(new URL(
            settings.getMotionFileName(group, index), modelBase));
          if (!response.ok) {
            throw new Error(`motion could not be loaded: ${group}[${index}]`);
          }
          const bytes = await response.arrayBuffer();
          const motion = CubismMotion.create(
            bytes, bytes.byteLength, undefined, undefined, true);
          if (!motion) throw new Error(`motion is invalid: ${group}[${index}]`);
          const fadeIn = settings.getMotionFadeInTimeValue(group, index);
          const fadeOut = settings.getMotionFadeOutTimeValue(group, index);
          if (fadeIn >= 0) motion.setFadeInTime(fadeIn);
          if (fadeOut >= 0) motion.setFadeOutTime(fadeOut);
          loaded[index] = motion;
        })());
      }
    }
    await Promise.all(tasks);
    for (const [semantic, group] of Object.entries(this.semanticMotions)) {
      if (!this.motions.get(group)?.length) {
        throw new Error(`semantic motion is unavailable: ${semantic}`);
      }
    }
  }

  private startSemanticMotion(
    semantic: ProceduralAction['action']
  ): boolean {
    const manager = this.motionManager;
    const group = this.semanticMotions[semantic];
    if (!group) {
      this.nativeMotionSemantic = null;
      return false;
    }
    const motions = this.motions.get(group);
    if (!manager || !motions?.length) {
      this.nativeMotionSemantic = null;
      return false;
    }
    const cursor = this.motionCursor.get(group) ?? 0;
    const motion = motions[cursor % motions.length];
    this.motionCursor.set(group, cursor + 1);
    motion.setLoop(semantic === 'idle' || semantic === 'walk');
    manager.stopAllMotions();
    manager.startMotionPriority(motion, false, semantic === 'idle' ? 1 : 3);
    this.nativeMotionSemantic = semantic;
    return true;
  }

  private resize(): void {
    if (!this.canvas || !this.gl) return;
    const ratio = window.devicePixelRatio || 1;
    const width = Math.max(1, Math.round(this.canvas.clientWidth * ratio));
    const height = Math.max(1, Math.round(this.canvas.clientHeight * ratio));
    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width;
      this.canvas.height = height;
    }
    this.gl.viewport(0, 0, width, height);
  }

  private parameterId(identifier: string) {
    return CubismFramework.getIdManager().getId(identifier);
  }

  private addParameter(identifier: string, value: number): void {
    this.model?.addParameterValueById(this.parameterId(identifier), value);
  }

  private activateGenerated(
    action: ProceduralAction,
    clip: ParameterClip
  ): void {
    this.motionManager?.stopAllMotions();
    this.nativeMotionSemantic = null;
    this.activeAction = {
      action: action.action,
      duration: clip.duration,
      intensity: Math.min(1, Math.max(0, Number(action.intensity) || 0)),
      clip,
      startedAt: performance.now()
    };
  }

  private activateGeneratedIdle(): void {
    if (this.nativeMotionSemantic === 'idle'
      || this.activeAction?.action === 'idle') return;
    if (this.startSemanticMotion('idle')) {
      this.activeAction = null;
      return;
    }
    if (this.generatedIdle) {
      this.activateGenerated({
        action: 'idle',
        duration: this.generatedIdle.duration,
        intensity: 1,
        clip: this.generatedIdle
      }, this.generatedIdle);
    }
  }

  private validatedClip(candidate: ParameterClip | undefined): ParameterClip | null {
    if (!candidate || !Number.isFinite(candidate.duration)
      || candidate.duration < 0.2 || candidate.duration > 10
      || typeof candidate.loop !== 'boolean'
      || !Array.isArray(candidate.frames) || candidate.frames.length < 2) {
      return null;
    }
    let previous = -1;
    for (const frame of candidate.frames) {
      if (!frame || !Number.isFinite(frame.time)
        || frame.time < previous || frame.time < 0
        || frame.time > candidate.duration
        || !frame.parameters || typeof frame.parameters !== 'object'
        || Object.entries(frame.parameters).some(
          ([identifier, value]) => identifier.length === 0 || !Number.isFinite(value))) {
        return null;
      }
      previous = frame.time;
    }
    return candidate;
  }

  private sampleClip(clip: ParameterClip, time: number): Record<string, number> {
    const frames = clip.frames;
    let upperIndex = frames.findIndex(frame => frame.time >= time);
    if (upperIndex < 0) upperIndex = frames.length - 1;
    if (upperIndex === 0) return frames[0].parameters;
    const lower = frames[upperIndex - 1];
    const upper = frames[upperIndex];
    const span = upper.time - lower.time;
    const progress = span > 0 ? (time - lower.time) / span : 1;
    const identifiers = new Set([
      ...Object.keys(lower.parameters), ...Object.keys(upper.parameters)
    ]);
    const sampled: Record<string, number> = {};
    for (const identifier of identifiers) {
      const start = lower.parameters[identifier] ?? 0;
      const end = upper.parameters[identifier] ?? 0;
      sampled[identifier] = start + (end - start) * progress;
    }
    return sampled;
  }

  private applyProceduralMotion(timestamp: number): void {
    if (!this.model) return;
    if (this.nativeMotionSemantic) return;
    let action = this.activeAction;
    if (!action) {
      this.activateGeneratedIdle();
      action = this.activeAction;
    }
    const clip = action?.clip;
    if (!action || !clip) return;

    let elapsed = Math.max(0, (timestamp - action.startedAt) / 1000);
    if (!clip.loop && elapsed >= clip.duration) {
      this.activeAction = null;
      this.activateGeneratedIdle();
      return;
    }
    const sampleTime = clip.loop
      ? elapsed % clip.duration
      : Math.min(elapsed, clip.duration);
    for (const [identifier, value] of Object.entries(
      this.sampleClip(clip, sampleTime))) {
      this.addParameter(identifier, value);
    }
  }

  private drawFrame = (timestamp: number): void => {
    if (!this.gl || !this.canvas || !this.model
        || !this.renderer || !this.modelMatrix) return;
    this.resize();
    const elapsed = Math.min(0.1, Math.max(0, (timestamp - this.lastFrameAt) / 1000));
    this.lastFrameAt = timestamp;
    if (!this.paused) {
      this.model.loadParameters();
      if (this.motionManager && !this.motionManager.isFinished()) {
        this.motionManager.updateMotion(this.model, elapsed);
        if (this.motionManager.isFinished()) {
          const completed = this.nativeMotionSemantic;
          this.nativeMotionSemantic = null;
          if (completed !== null && completed !== 'idle' && completed !== 'walk') {
            this.activeAction = null;
            if (!this.startSemanticMotion('idle')) this.activateGeneratedIdle();
          }
        }
      }
      for (const [identifier, target] of this.targetParameters) {
        const current = this.currentParameters.get(identifier) ?? 0;
        const responseTime = identifier.startsWith('ParamEyeBall')
          ? 0.055 : identifier.startsWith('ParamAngle') ? 0.11 : 0.20;
        const parameterBlend = 1 - Math.exp(-elapsed / responseTime);
        const next = current + (target - current) * parameterBlend;
        this.currentParameters.set(identifier, next);
        this.addParameter(identifier, next);
      }
      this.applyProceduralMotion(timestamp);
      this.model.update();
    }

    this.gl.clearColor(0, 0, 0, 0);
    this.gl.clear(this.gl.COLOR_BUFFER_BIT);
    CubismWebGLOffscreenManager.getInstance().beginFrameProcess(this.gl);
    const projection = new CubismMatrix44();
    projection.scale(this.canvas.height / this.canvas.width, 1);
    projection.multiplyByMatrix(this.modelMatrix);
    this.renderer.setMvpMatrix(projection);
    this.renderer.setRenderState(null, [
      0, 0, this.canvas.width, this.canvas.height]);
    this.renderer.drawModel(this.shaderPath);
    CubismWebGLOffscreenManager.getInstance().endFrameProcess(this.gl);
    this.animationFrame = requestAnimationFrame(this.drawFrame);
  };
}

const runtime = new Runtime();

export async function boot(options: BootOptions): Promise<void> {
  return runtime.boot(options);
}

export function setParameters(parameters: Record<string, number>): void {
  runtime.setParameters(parameters);
}

export function setPaused(paused: boolean): void {
  runtime.setPaused(paused);
}

export function triggerAction(action: ProceduralAction): void {
  runtime.triggerAction(action);
}

export function pixelProbe(): number {
  return runtime.pixelProbe();
}

export function release(): void {
  runtime.release();
}
