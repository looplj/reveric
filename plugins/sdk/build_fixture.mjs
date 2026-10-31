import {build} from 'esbuild';
import {copyFile,mkdir} from 'node:fs/promises';
import {tsxPlugin} from './tsx_transform.mjs';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const here=dirname(fileURLToPath(import.meta.url));
await build({entryPoints:[resolve(here,'fixtures/counter.tsx')],outfile:resolve(here,'../../third/fjs/libfjs/src/ui/fixtures/counter.js'),
  bundle:true,format:'iife',globalName:'__revericView',platform:'neutral',target:'es2020',sourcemap:'inline',plugins:[tsxPlugin()]});

await mkdir(resolve(here,'../../assets/plugin_preview'),{recursive:true});
await copyFile(resolve(here,'../../third/fjs/libfjs/src/ui/fixtures/counter.js'),resolve(here,'../../assets/plugin_preview/counter.js'));
