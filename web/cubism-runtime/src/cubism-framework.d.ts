declare module '@framework/live2dcubismframework' {
  export class Option {
    logFunction?: (message: string) => void;
  }
  export class CubismFramework {
    static isStarted(): boolean;
    static startUp(option: Option): void;
    static initialize(): void;
    static getIdManager(): { getId(identifier: string): unknown };
  }
}

declare module '@framework/cubismmodelsettingjson' {
  export class CubismModelSettingJson {
    constructor(buffer: ArrayBuffer, size: number);
    getModelFileName(): string;
    getTextureCount(): number;
    getTextureFileName(index: number): string;
    getMotionGroupCount(): number;
    getMotionGroupName(index: number): string;
    getMotionCount(group: string): number;
    getMotionFileName(group: string, index: number): string;
    getMotionFadeInTimeValue(group: string, index: number): number;
    getMotionFadeOutTimeValue(group: string, index: number): number;
  }
}

declare module '@framework/model/cubismmodel' {
  export class CubismModel {
    getCanvasWidth(): number;
    getCanvasHeight(): number;
    getDrawableIndex(id: unknown): number;
    getParameterIndex(id: unknown): number;
    setParameterValueById(id: unknown, value: number, weight?: number): void;
    addParameterValueById(id: unknown, value: number, weight?: number): void;
    saveParameters(): void;
    loadParameters(): void;
    update(): void;
  }
}

declare module '@framework/motion/acubismmotion' {
  export class ACubismMotion {
    static delete(motion: ACubismMotion): void;
    setLoop(loop: boolean): void;
    setFadeInTime(seconds: number): void;
    setFadeOutTime(seconds: number): void;
  }
}

declare module '@framework/motion/cubismmotion' {
  import type { ACubismMotion } from '@framework/motion/acubismmotion';
  export class CubismMotion extends ACubismMotion {
    static create(
      buffer: ArrayBuffer,
      size: number,
      onFinished?: (() => void),
      onBegan?: (() => void),
      consistencyCheck?: boolean
    ): CubismMotion | null;
  }
}

declare module '@framework/motion/cubismmotionmanager' {
  import type { CubismModel } from '@framework/model/cubismmodel';
  import type { ACubismMotion } from '@framework/motion/acubismmotion';
  export class CubismMotionManager {
    isFinished(): boolean;
    updateMotion(model: CubismModel, elapsedSeconds: number): boolean;
    stopAllMotions(): void;
    startMotionPriority(
      motion: ACubismMotion, autoDelete: boolean, priority: number
    ): unknown;
    release(): void;
  }
}

declare module '@framework/model/cubismmoc' {
  import type { CubismModel } from '@framework/model/cubismmodel';
  export class CubismMoc {
    static create(buffer: ArrayBuffer, consistencyCheck?: boolean): CubismMoc | null;
    createModel(): CubismModel | null;
    deleteModel(model: CubismModel): void;
    release(): void;
  }
}

declare module '@framework/math/cubismmodelmatrix' {
  export class CubismModelMatrix {
    constructor(width: number, height: number);
  }
}

declare module '@framework/math/cubismmatrix44' {
  import type { CubismModelMatrix } from '@framework/math/cubismmodelmatrix';
  export class CubismMatrix44 {
    scale(x: number, y: number): void;
    multiplyByMatrix(matrix: CubismModelMatrix): void;
  }
}

declare module '@framework/rendering/cubismrenderer_webgl' {
  import type { CubismModel } from '@framework/model/cubismmodel';
  import type { CubismMatrix44 } from '@framework/math/cubismmatrix44';
  export class CubismRenderer_WebGL {
    constructor(width: number, height: number);
    initialize(model: CubismModel): void;
    startUp(context: WebGL2RenderingContext): void;
    setIsPremultipliedAlpha(enabled: boolean): void;
    loadShaders(path: string): void;
    bindTexture(index: number, texture: WebGLTexture): void;
    setMvpMatrix(matrix: CubismMatrix44): void;
    setRenderState(framebuffer: WebGLFramebuffer | null, viewport: number[]): void;
    drawModel(shaderPath: string): void;
    release(): void;
  }
}

declare module '@framework/rendering/cubismoffscreenmanager' {
  export class CubismWebGLOffscreenManager {
    static getInstance(): CubismWebGLOffscreenManager;
    beginFrameProcess(context: WebGL2RenderingContext): void;
    endFrameProcess(context: WebGL2RenderingContext): void;
  }
}
