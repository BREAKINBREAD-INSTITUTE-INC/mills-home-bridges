// Render a Design-canvas .dc.html board to a standalone HTML page.
// Usage: node dc_render.js <board.dc.html> <out.html>
const fs=require('fs');
const src=process.argv[2], out=process.argv[3];
let html=fs.readFileSync(src,'utf8');
const sm=html.match(/<script type="text\/x-dc"[^>]*>([\s\S]*?)<\/script>/);
class DCLogic{constructor(){this.props={};}}
let data={};
try{ const f=new Function('DCLogic', sm[1]+'\nreturn new Component();');
  const inst=f(DCLogic); inst.props=inst.props||{}; data=inst.renderVals();
}catch(e){console.error('renderVals error:',e);process.exit(1);}
const helmet=(html.match(/<helmet>([\s\S]*?)<\/helmet>/)||[,''])[1];
let body=(html.match(/<\/helmet>([\s\S]*?)<\/x-dc>/)||[,''])[1];
const get=(o,p)=>p.split('.').reduce((a,k)=>a==null?undefined:a[k],o);
const subst=(s,ctx)=>s.replace(/\{\{\s*([\w.$]+)\s*\}\}/g,(m,p)=>{const v=get(ctx,p);return v==null?'':String(v);});
body=body.replace(/<sc-for\s+list="\{\{\s*([\w.$]+)\s*\}\}"\s+as="(\w+)"[^>]*>([\s\S]*?)<\/sc-for>/g,
  (m,list,as,inner)=>{const arr=get(data,list)||[];return arr.map(it=>{const c=Object.assign({},data);c[as]=it;return subst(inner,c);}).join('');});
body=subst(body,data);
fs.writeFileSync(out,`<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n<title>MILLS OS — Mission Control</title>\n${helmet}\n</head>\n<body>\n${body}\n</body>\n</html>`);
console.log('rendered',out);
