import ts from 'typescript';
import { readFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const sdk = dirname(fileURLToPath(import.meta.url));
const schema = JSON.parse(await readFile(resolve(sdk,'ui.schema.json'),'utf8'));
const uiTypes = resolve(sdk,'ui.d.ts');

export function transformTsx(source, filename) {
  filename = resolve(filename);
  const options = {target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.ESNext,
    moduleResolution:ts.ModuleResolutionKind.Bundler,jsx:ts.JsxEmit.Preserve,
    strict:true,skipLibCheck:true,sourceMap:true,inlineSources:true,types:[],lib:['lib.es2020.d.ts']};
  const host = ts.createCompilerHost(options);
  const original = host.getSourceFile.bind(host);
  host.getSourceFile = (name,version,onError,createNew) => resolve(name) === filename
    ? ts.createSourceFile(filename,source,version,true,ts.ScriptKind.TSX)
    : original(name,version,onError,createNew);
  const program = ts.createProgram([filename,uiTypes,resolve(sdk,'index.d.ts')],options,host);
  const file = program.getSourceFile(filename), checker = program.getTypeChecker();
  const diagnostics = ts.getPreEmitDiagnostics(program);
  if (diagnostics.length) throw new Error(ts.formatDiagnosticsWithColorAndContext(diagnostics,{
    getCurrentDirectory:()=>process.cwd(),getCanonicalFileName:name=>name,getNewLine:()=> '\n',
  }));
  let javascript, map;
  const factory = ts.factory;
  const runtime = name => factory.createPropertyAccessExpression(factory.createPropertyAccessExpression(factory.createIdentifier('globalThis'),'__revericUi'),name);
  const call = (name,args) => factory.createCallExpression(runtime(name),undefined,args);
  const transformer = context => {
    const fail = (node,message) => {
      const position = file.getLineAndCharacterOfPosition(node.getStart(file));
      throw new Error(`${filename}:${position.line+1}:${position.character+1}: ${message}`);
    };
    const getter = (name,value) => factory.createGetAccessorDeclaration(undefined,name,[],undefined,
      factory.createBlock([factory.createReturnStatement(value)],true));
    // A shared children getter would re-run every sibling when one expression
    // changes, so each dynamic expression owns a Fragment slot (like insert()).
    const isStatic = expression => {
      while (ts.isParenthesizedExpression(expression)) expression=expression.expression;
      return ts.isJsxElement(expression)||ts.isJsxSelfClosingElement(expression)||ts.isJsxFragment(expression)||ts.isIdentifier(expression);
    };
    function children(nodes) {
      const dynamic=nodes.filter(node=>ts.isJsxExpression(node)&&node.expression&&!isStatic(node.expression));
      const present=nodes.filter(node=>ts.isJsxText(node)?node.text.trim():!ts.isJsxExpression(node)||node.expression);
      const isolate=present.length>1&&dynamic.length>0;
      return nodes.flatMap(node => {
        if (ts.isJsxText(node)) {
          const text = node.text.replace(/\s+/g,' ').trim();
          if (!text) return [];
          return [call('element',[factory.createStringLiteral('Text'),factory.createObjectLiteralExpression([
            factory.createPropertyAssignment('text',factory.createStringLiteral(text)),
          ])])];
        }
        if (ts.isJsxExpression(node)) {
          if (!node.expression) return [];
          const value=ts.visitNode(node.expression,visit);
          return [isolate&&dynamic.includes(node)?call('element',[factory.createStringLiteral('Fragment'),
            factory.createObjectLiteralExpression([getter('children',value)])]):value];
        }
        return [ts.visitNode(node,visit)];
      });
    }
    function visit(node) {
      if (ts.isJsxFragment(node)) {
        const nodes=children(node.children);
        return call('element',[factory.createStringLiteral('Fragment'),factory.createObjectLiteralExpression([
          getter('children',factory.createArrayLiteralExpression(nodes)),
        ])]);
      }
      if (ts.isJsxElement(node)||ts.isJsxSelfClosingElement(node)) {
        const opening=ts.isJsxElement(node)?node.openingElement:node;
        const tag=opening.tagName;
        const name=ts.isIdentifier(tag)?tag.text:ts.isPropertyAccessExpression(tag)?tag.name.text:'';
        if (!/^[A-Z]/.test(name)) fail(tag,'Only PascalCase component bindings are supported');
        let symbol=checker.getSymbolAtLocation(ts.isPropertyAccessExpression(tag)?tag.name:tag);
        if (!symbol) fail(tag,'Unresolved component binding');
        if (symbol.flags & ts.SymbolFlags.Alias) symbol=checker.getAliasedSymbol(symbol);
        if (!checker.getTypeOfSymbolAtLocation(symbol,tag).getCallSignatures().length) fail(tag,'Component must be callable');
        const props=[];
        for (const attribute of opening.attributes.properties) {
          if (ts.isJsxSpreadAttribute(attribute)) fail(attribute,'List component properties explicitly; JSX spreads are not supported');
          const key=attribute.name.getText(file);
          const initializer=attribute.initializer;
          let value;
          if (!initializer) value=factory.createTrue();
          else if (ts.isStringLiteral(initializer)) value=initializer;
          else if (ts.isJsxExpression(initializer)&&initializer.expression) value=ts.visitNode(initializer.expression,visit);
          else fail(attribute,'Invalid JSX attribute');
          const literal=ts.isStringLiteral(value)||ts.isNumericLiteral(value)||value.kind===ts.SyntaxKind.TrueKeyword||value.kind===ts.SyntaxKind.FalseKeyword||value.kind===ts.SyntaxKind.NullKeyword;
          const eventFunction=key.startsWith('on')&&(ts.isArrowFunction(value)||ts.isFunctionExpression(value));
          props.push(literal||eventFunction?factory.createPropertyAssignment(factory.createStringLiteral(key),value):getter(factory.createStringLiteral(key),value));
        }
        if (ts.isJsxElement(node)) {
          const nodes=children(node.children);
          if (nodes.length) props.push(getter('children',nodes.length===1?nodes[0]:factory.createArrayLiteralExpression(nodes)));
        }
        // Keep the resolved lexical binding itself; aliases and shadowed names
        // must never be rewritten to a component string by identifier spelling.
        // Only a binding that resolves to a schema component in reveric/ui may
        // skip the component root and create its host element directly.
        const declaration=symbol.declarations?.[0];
        const definition=schema.components[symbol.name];
        const builtin=declaration&&resolve(declaration.getSourceFile().fileName)===uiTypes&&definition&&!definition.internal&&!helpers.includes(symbol.name);
        const object=factory.createObjectLiteralExpression(props,true);
        return builtin?call('element',[factory.createStringLiteral(symbol.name),object]):call('component',[tag,object]);
      }
      return ts.visitEachChild(node,visit,context);
    }
    return file => ts.visitNode(file,visit);
  };
  program.emit(file,(name,text)=>{
    if (/\.jsx?$/.test(name)) javascript=text;
    if (/\.map$/.test(name)) map=text;
  },undefined,false,{before:[transformer]});
  if (!javascript||!map) throw new Error(`No TSX output for ${filename}`);
  javascript=javascript.replace(/\/\/# sourceMappingURL=.*$/m,`//# sourceMappingURL=data:application/json;base64,${Buffer.from(map).toString('base64')}`);
  return {javascript,map:JSON.parse(map)};
}

const helpers=['signal','computed','effect','batch','untracked','cleanup','resource','mount','If','Each','ErrorBoundary','List','Tabs'];
export const nativeUiModule = [...helpers.map(name=>`export const ${name}=globalThis.__revericUi.${name};`),
  ...Object.keys(schema.components).filter(name=>!schema.components[name].internal&&!helpers.includes(name))
    .map(name=>`export const ${name}=props=>globalThis.__revericUi.element(${JSON.stringify(name)},props);`)].join('\n');
export function tsxPlugin() {
  return {name:'reveric-native-tsx',setup(build){
    build.onResolve({filter:/^reveric\/ui$/},()=>({path:'reveric/ui',namespace:'reveric-ui'}));
    build.onLoad({filter:/.*/,namespace:'reveric-ui'},()=>({contents:nativeUiModule,loader:'js'}));
    build.onLoad({filter:/\.tsx$/},async args=>{
      const source=await readFile(args.path,'utf8');
      return {contents:transformTsx(source,args.path).javascript,loader:'js',resolveDir:dirname(args.path)};
    });
  }};
}
