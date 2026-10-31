import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
const source=await readFile(new URL('./sqlite_runtime.js',import.meta.url),'utf8');
function api(call) {
  const context=vm.createContext({Uint8Array}); vm.runInContext(source,context);
  return context.__revericSqlite(call);
}
test('SQLite codec preserves int64/blob and never decodes a row as a cell tag',async()=>{
  const calls=[];
  const db=api(async(method,args)=>{
    calls.push([method,JSON.parse(JSON.stringify(args))]);
    if(method==='sqlite.query') return [{big:{__revericSql:'int64',value:'9223372036854775807'},blob:{__revericSql:'blob',value:'AP8B'},__revericSql:'int64',value:'not a tagged cell'}];
    return {changes:1,lastInsertRowId:{__revericSql:'int64',value:'7'}};
  });
  const result=await db.query({sql:'SELECT ?',params:[9223372036854775807n,new Uint8Array([0,255,1])]});
  assert.equal(result[0].big,9223372036854775807n);
  assert.deepEqual([...result[0].blob],[0,255,1]);
  assert.equal(result[0].value,'not a tagged cell');
  assert.deepEqual(calls[0][1].statement.params,[{__revericSql:'int64',value:'9223372036854775807'},{__revericSql:'blob',value:'AP8B'}]);
  assert.equal((await db.execute({sql:'INSERT'})).lastInsertRowId,7n);
});
test('SQLite codec rejects unsafe numbers and unsupported parameter objects',async()=>{
  const db=api(()=>{throw Error('Bridge must not be reached');});
  for(const value of [Number.MAX_SAFE_INTEGER+1,Infinity,NaN,1n<<63n,true,{},undefined]) {
    await assert.rejects(db.query({sql:'SELECT ?',params:[value]}),e=>e.code==='invalid_argument');
  }
});
