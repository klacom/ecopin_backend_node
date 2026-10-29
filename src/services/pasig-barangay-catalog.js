// Canonical PSA roster: https://psa.gov.ph/classification/psgc/barangays/1381200000
export const PASIG_BARANGAYS = [
 'Bagong Ilog','Bagong Katipunan','Bambang','Buting','Caniogan','Dela Paz','Kalawaan','Kapasigan','Kapitolyo','Malinao',
 'Manggahan','Maybunga','Oranbo','Palatiw','Pinagbuhatan','Pineda','Rosario','Sagad','San Antonio','San Joaquin','San Jose',
 'San Miguel','San Nicolas','Santa Cruz','Santa Rosa','Santo Tomas','Santolan','Sumilang','Ugong','Santa Lucia',
].map((name,i)=>({name,psgc_code:`1381200${String(i+1).padStart(3,'0')}`}));
export const OFFICIAL_PASIG_BARANGAYS=new Set(PASIG_BARANGAYS.map(row=>row.name));
const key=value=>String(value??'').trim().toLowerCase().replace(/^(barangay|brgy\.?)\s+/,'').replace(/[.\s_-]+/g,' ');
const names=new Map(PASIG_BARANGAYS.map(row=>[key(row.name),row.name]));
for(const [alias,name] of [['de la paz','Dela Paz'],['sta cruz','Santa Cruz'],['sta lucia','Santa Lucia'],['sta rosa','Santa Rosa'],['sto tomas','Santo Tomas']]) names.set(alias,name);
export const normalizePasigBarangay=value=>names.get(key(value))??null;
export const isOrtigasDistrict=value=>/^ortigas (center|centre)$/i.test(String(value??'').trim());

export function preparePasigBoundaryRows(collection) {
 if(collection?.type!=='FeatureCollection'||!Array.isArray(collection.features)||collection.features.length!==30)throw new Error('Exactly 30 source barangay features are required.');
 const seen=new Set();
 return collection.features.map(feature=>{
  const p=feature.properties??{},code=String(p.adm4_psgc??p.psgc_code??'');
  const official=PASIG_BARANGAYS.find(row=>row.psgc_code===code);
  const name=normalizePasigBarangay(p.adm4_en??p.name??p.NAME_4);
  if(!official||name!==official.name||seen.has(code))throw new Error('Missing, duplicate or inconsistent Pasig PSGC/name: '+code+' '+(p.adm4_en??p.name??''));
  if(p.adm3_psgc!=null&&String(p.adm3_psgc)!=='1381200000')throw new Error('Source municipality is not Pasig.');
  if(!['Polygon','MultiPolygon'].includes(feature.geometry?.type))throw new Error('Polygon geometry required for '+name);
  seen.add(code);return {name,psgc_code:code,geometry:feature.geometry};
 });
}
