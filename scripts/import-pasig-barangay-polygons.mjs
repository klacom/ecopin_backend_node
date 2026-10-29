import {parseArgs} from 'node:util';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {preparePasigBoundaryRows} from '../src/services/pasig-barangay-catalog.js';
const {values:args}=parseArgs({options:{input:{type:'string'},'source-url':{type:'string'},sha256:{type:'string'},confirm:{type:'boolean',default:false},'dry-run':{type:'boolean',default:false},help:{type:'boolean',default:false}}});
if(args.help||!args.input){
 console.log('Usage: node scripts/import-pasig-barangay-polygons.mjs --input <GeoJSON> [--dry-run]\nApply only after review: add --confirm --source-url <HTTPS source> --sha256 <reviewed file SHA-256>');
}else{
 if(args.confirm&&args['dry-run'])throw new Error('Choose dry-run or confirm, not both.');
 const bytes=await readFile(args.input);const sha256=createHash('sha256').update(bytes).digest('hex');
 const rows=preparePasigBoundaryRows(JSON.parse(bytes.toString('utf8')));
 if(args.sha256&&args.sha256!==sha256)throw new Error('Source checksum does not match the reviewed file.');
 console.log(JSON.stringify({mode:args.confirm?'apply':'dry-run',count:rows.length,sha256,names:rows.map(r=>r.name),geometry_validation:'PostGIS validation/overlap checks run inside the atomic import; use the geometry audit before applying.'},null,2));
 if(args.confirm){
  if(!args.sha256||!args['source-url']?.startsWith('https://'))throw new Error('Applying requires reviewed SHA-256 and an HTTPS provenance URL.');
  const {supabaseAdmin}=await import('../src/config/supabase.config.js');
  const {data,error}=await supabaseAdmin.rpc('import_pasig_barangay_boundaries',{rows,source_url:args['source-url'],source_sha256:sha256});
  if(error)throw new Error(error.message);console.log(JSON.stringify(data));
 }
}
