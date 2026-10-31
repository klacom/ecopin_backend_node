import {OSRM_BASE_URL} from '../config/index.js';

// Pasig City and surroundings; refuses to relay arbitrary coordinates to the routing engine.
const BOUNDS={minLat:14.40,maxLat:14.75,minLng:120.95,maxLng:121.25};

export function parsePoint(value){
    const match=/^(-?\d{1,3}(?:\.\d{1,8})?),(-?\d{1,3}(?:\.\d{1,8})?)$/.exec(String(value??''));
    if(!match)return null;
    const lng=Number(match[1]),lat=Number(match[2]);
    if(lat<BOUNDS.minLat||lat>BOUNDS.maxLat||lng<BOUNDS.minLng||lng>BOUNDS.maxLng)return null;
    return {lat,lng};
}

/**
 * GET /api/routing/directions?from=lng,lat&to=lng,lat
 * Server-side proxy for turn-by-turn directions so the mobile app never calls a public demo router directly.
 */
export async function getDrivingDirections(req,res){
    const from=parsePoint(req.query.from),to=parsePoint(req.query.to);
    if(!from||!to)return res.status(400).json({message:'Provide from and to as "lng,lat" inside the Pasig service area.'});
    const url=`${OSRM_BASE_URL.replace(/\/$/,'')}/route/v1/driving/${from.lng},${from.lat};${to.lng},${to.lat}?steps=true&geometries=geojson&overview=full`;
    try{
        const response=await fetch(url,{signal:AbortSignal.timeout(8000),headers:{'User-Agent':'EcoPin-Backend/1.0'}});
        if(!response.ok)return res.status(502).json({message:'Directions are temporarily unavailable.'});
        res.set('Cache-Control','private, max-age=30').status(200).json(await response.json());
    }catch(error){
        res.status(504).json({message:'Directions are temporarily unavailable.'});
    }
}
