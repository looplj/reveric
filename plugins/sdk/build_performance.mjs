import {build} from 'esbuild';
import {tsxPlugin} from './tsx_transform.mjs';
import {fileURLToPath} from 'node:url';
await build({entryPoints:[fileURLToPath(new URL('./fixtures/performance.tsx',import.meta.url))],outfile:fileURLToPath(new URL('../../assets/plugin_preview/performance.js',import.meta.url)),bundle:true,format:'iife',globalName:'__revericView',platform:'neutral',target:'es2020',sourcemap:'inline',plugins:[tsxPlugin()]});
