import {execFileSync} from 'node:child_process';
process.chdir('C:/dev/ecopin/.tmp/parity-recovery-backend');
const {supabaseAdmin:db}=await import('file:///C:/dev/ecopin/.tmp/parity-recovery-backend/src/config/supabase.config.js');
const id='a0900000-0000-4000-8000-000000000001';
const psql=q=>execFileSync('docker',['exec','-i','supabase_db_parity-recovery-backend','psql','-X','-qAt','-U','postgres','-d','postgres','-c',q],{encoding:'utf8'}).trim();
const names=psql(`select name from storage.objects where bucket_id='Cleanup Proof' and name like '${id}/%'`).split('\n').filter(Boolean);
if(names.length){const {error}=await db.storage.from('Cleanup Proof').remove(names);if(error)throw error;}
psql(`delete from cleanup_proof_publications where report_id='${id}'`);
console.log('reset; remaining proof objects:',psql(`select count(*) from storage.objects where bucket_id='Cleanup Proof' and name like '${id}/%'`));
