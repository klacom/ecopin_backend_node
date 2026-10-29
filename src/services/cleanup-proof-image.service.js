import {createCanvas,loadImage} from 'canvas';
let rendering=false;

export function validateRedactions(regions) {
 if(!Array.isArray(regions)||regions.length>100) throw new Error('Provide up to 100 redaction rectangles');
 for(const r of regions){
  if(!r||!['x','y','width','height'].every(k=>typeof r[k]==='number'&&Number.isFinite(r[k]))||
   r.x<0||r.y<0||r.width<=0||r.height<=0||r.x+r.width>1||r.y+r.height>1) throw new Error('Invalid redaction rectangle');
 }
 return regions;
}

export async function redactCleanupImage(buffer,regions) {
 validateRedactions(regions);
 if(rendering)throw Object.assign(new Error('Another proof image is processing. Please retry.'),{statusCode:503});
 rendering=true;
 try {
 const image=await loadImage(buffer);
 if(image.width*image.height>20000000) throw new Error('Photo exceeds the 20 megapixel review limit');
 const canvas=createCanvas(image.width,image.height),ctx=canvas.getContext('2d');
 ctx.drawImage(image,0,0);ctx.fillStyle='#000000';
 for(const r of regions)ctx.fillRect(Math.floor(r.x*image.width),Math.floor(r.y*image.height),Math.ceil(r.width*image.width)+1,Math.ceil(r.height*image.height)+1);
 // A fresh JPEG contains only rendered pixels, without original EXIF/GPS metadata.
 return canvas.toBuffer('image/jpeg',{quality:0.9});
 } finally {rendering=false;}
}
