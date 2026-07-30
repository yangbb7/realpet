import path from 'node:path';
import { defineConfig } from 'vite';

const frameworkRoot = process.env.CUBISM_FRAMEWORK_DIR;
if (!frameworkRoot) {
  throw new Error('CUBISM_FRAMEWORK_DIR must point to Cubism Web Framework');
}

export default defineConfig({
  resolve: {
    alias: {
      '@framework': path.resolve(frameworkRoot, 'src')
    }
  },
  build: {
    emptyOutDir: true,
    lib: {
      entry: path.resolve(__dirname, 'src/runtime.ts'),
      name: 'RealPetCubism',
      formats: ['iife'],
      fileName: () => 'realpet-cubism.bundle.js'
    },
    minify: true,
    sourcemap: true
  }
});
