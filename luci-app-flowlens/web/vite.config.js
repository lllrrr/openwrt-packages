import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'node:path';

export default defineConfig({
  plugins: [react()],
  define: {
    'process.env.NODE_ENV': JSON.stringify('production')
  },
  build: {
    outDir: '../htdocs/luci-static/resources/flowlens/dist',
    emptyOutDir: true,
    cssCodeSplit: false,
    lib: {
      entry: resolve(__dirname, 'src/main.jsx'),
      name: 'FlowLensApp',
      formats: ['iife'],
      fileName: () => 'flowlens-app.js'
    },
    rollupOptions: {
      output: {
        assetFileNames: assetInfo => assetInfo.name?.endsWith('.css')
          ? 'flowlens-app.css'
          : 'assets/[name][extname]',
        inlineDynamicImports: true
      }
    }
  }
});
