// T09 synthetic proof fixture for the isolated database only: one completed report with two Before and two After originals.
// Each original is a distinct synthetic JPEG with a coloured "sensitive" block and an injected COM marker that must not survive redaction.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createCanvas} from 'canvas';
import {supabaseAdmin as db} from '../src/config/supabase.config.js';
import {storageReference} from '../src/services/storage-reference.js';
assert.equal(process.env.SUPABASE_URL,'http://127.0.0.1:54321','Only the isolated database is permitted.');
export const REPORT='a0900000-0000-4000-8000-000000000001',MARKER='T09_SENSITIVE_METADATA_MARKER';
const ids={before:['b0900000-0000-4000-8000-000000000001','b0900000-0000-4000-8000-000000000002'],after:['c0900000-0000-4000-8000-000000000001','c0900000-0000-4000-8000-000000000002']};
// Sensitive block position (fractions) is the same in every image so redaction can be checked by pixel sampling.
export const BLOCK={x:0.5,y:0.5,width:0.25,height:0.25};
const colours={before:['#c0392b','#8e44ad'],after:['#27ae60','#2980b9']};
function jpeg(colour,label){
 const c=createCanvas(400,300),x=c.getContext('2d');x.fillStyle=colour;x.fillRect(0,0,400,300);
 x.fillStyle='#ffff00';x.fillRect(BLOCK.x*400,BLOCK.y*300,BLOCK.width*400,BLOCK.height*300);x.fillStyle='#000';x.font='20px sans-serif';x.fillText(label,10,30);
 const raw=c.toBuffer('image/jpeg',{quality:0.9}),text=Buffer.from(MARKER),com=Buffer.alloc(4+text.length);
 com[0]=0xff;com[1]=0xfe;com.writeUInt16BE(text.length+2,2);text.copy(com,4);
 return Buffer.concat([raw.subarray(0,2),com,raw.subarray(2)]);
}
export const original=(slot,i)=>jpeg(colours[slot][i],`T09 ${slot} ${i+1}`);
export const originalPath=(slot,i)=>`${REPORT}/${slot}/${ids[slot][i]}.jpg`;
const refs={};
for(const slot of ['before','after'])refs[slot]=ids[slot].map((_,i)=>storageReference('Cleanup Originals',originalPath(slot,i)));
if(import.meta.url===`file://${process.argv[1].replaceAll('\\','/').replace(/^([A-Za-z]):/,'/$1:')}`||process.argv[1]?.endsWith('seed-proof-fixture-t09.mjs')){
 for(const slot of ['before','after'])for(const i of [0,1]){
  const {error}=await db.storage.from('Cleanup Originals').upload(originalPath(slot,i),original(slot,i),{contentType:'image/jpeg',upsert:true});assert.ifError(error);
 }
 const photos=slot=>JSON.stringify(refs[slot].map(url=>({url})));
 const sql=`BEGIN;
DO $$ BEGIN IF EXISTS(SELECT 1 FROM public.reports WHERE id='${REPORT}' AND title NOT LIKE 'T09_SYNTHETIC_%') THEN RAISE EXCEPTION 'Reserved T09 ID owned by other data'; END IF; END $$;
INSERT INTO public.reports(id,title,description,user_id,location,created_at,status,validation_status,street_address,barangay,city,lgu_resolved_at,cleanup_action_notes,
 before_photo_url,after_photo_url,before_photo_hash,after_photo_hash,before_photos,after_photos)
SELECT '${REPORT}','T09_SYNTHETIC_PROOF','T09 synthetic report',u.id,extensions.ST_SetSRID(extensions.ST_Point(121.0801,14.5731),4326)::extensions.geography,
 '2026-11-01 02:00:00Z','resolved','approved','Synthetic Street 9','Synthetic Barangay','Pasig City','2026-11-02 04:00:00Z','Crew note T09 (not copied to the public).',
 '${refs.before[0]}','${refs.after[0]}','t09-before-hash-1','t09-after-hash-1','${photos('before')}'::jsonb,'${photos('after')}'::jsonb
FROM auth.users u WHERE u.email='citizen-a@parity.ecopin.invalid' AND u.raw_app_meta_data->>'fixture'='ecopin-parity-local'
ON CONFLICT(id) DO NOTHING;
COMMIT;`;
 execFileSync('docker',['exec','-i','supabase_db_parity-recovery-backend','psql','-X','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres'],{input:sql,stdio:['pipe','inherit','inherit']});
 console.log('T09 fixture ready:',REPORT);process.exit(0);
}
