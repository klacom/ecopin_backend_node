// Controlled classifier inference through the backend's own client and configured endpoint, using synthetic images only (no report, no database, no storage).
// Usable on the production host for release acceptance: `node scripts/check-classifier-inference.mjs` from the release directory.
// Prints one JSON line per image (contract fields and timing, never the endpoint) and exits non-zero if any image fails the contract
// or the first answer exceeds the backend client's 30 s budget.
import sharp from 'sharp';
import {classifyImage,ALLOWED_PREDICTED_CLASSES,ALLOWED_CLASSIFIER_CATEGORIES} from '../src/services/classifierClient.service.js';
const FIRST_ANSWER_BUDGET_MS=30000;
const make=async kind=>{
 const w=640,h=480,raw=Buffer.alloc(w*h*3);
 for(let y=0;y<h;y++)for(let x=0;x<w;x++){const i=(y*w+x)*3;
  if(kind==='gray'){raw[i]=raw[i+1]=raw[i+2]=128;}
  else if(kind==='gradient'){raw[i]=x*255/w;raw[i+1]=y*255/h;raw[i+2]=(x+y)*255/(w+h);}
  else{raw[i]=Math.random()*255;raw[i+1]=Math.random()*255;raw[i+2]=Math.random()*255;}}
 return sharp(raw,{raw:{width:w,height:h,channels:3}}).jpeg({quality:85}).toBuffer();
};
const say=console.log;console.log=()=>{};console.warn=()=>{};console.error=()=>{}; // the client logs request details; keep only the summary lines
let failed=false;
for(const [n,kind] of ['gray','gradient','noise','gray'].entries()){
 const buffer=await make(kind),started=Date.now(),r=await classifyImage(buffer,`check-${kind}.jpg`,'image/jpeg'),ms=Date.now()-started;
 const contract=!!(r.ok&&ALLOWED_PREDICTED_CLASSES.includes(r.predicted_class)&&typeof r.confidence==='number'&&r.confidence>=0&&r.confidence<=1&&r.probabilities&&typeof r.probabilities==='object'
  &&typeof r.decision==='string'&&typeof r.in_review_zone==='boolean'&&(r.predicted_category===null||ALLOWED_CLASSIFIER_CATEGORIES.includes(r.predicted_category)));
 const withinBudget=n>0||ms<=FIRST_ANSWER_BUDGET_MS;
 if(!contract||!withinBudget)failed=true;
 say(JSON.stringify({kind,ok:r.ok,ms,contract,withinBudget,predicted_class:r.predicted_class,decision:r.decision,confidence:r.ok?+Number(r.confidence).toFixed(3):null,in_review_zone:r.in_review_zone,error:r.ok?undefined:String(r.error).slice(0,100)}));
}
process.exit(failed?1:0);
