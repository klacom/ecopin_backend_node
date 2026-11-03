import {OSRM_BASE_URL} from '../config/index.js';

// Pasig City and surroundings; refuses to relay arbitrary coordinates to the routing engine.
const BOUNDS={minLat:14.40,maxLat:14.75,minLng:120.95,maxLng:121.25};

// Phone GPS reports 14-16 decimals; routing needs about 0.1 m, so accept long input and round to 6 places.
const round6=n=>Math.round(n*1e6)/1e6;

export function parsePoint(value){
    const match=/^(-?\d{1,3}(?:\.\d{1,15})?),(-?\d{1,3}(?:\.\d{1,15})?)$/.exec(String(value??''));
    if(!match)return null;
    const lng=round6(Number(match[1])),lat=round6(Number(match[2]));
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
    const unavailable={message:'Directions are temporarily unavailable.'};
    let response,body;
    try{
        response=await fetch(url,{signal:AbortSignal.timeout(8000),headers:{'User-Agent':'EcoPin-Backend/1.0'}});
        body=await response.json().catch(()=>null);
    }catch(error){
        return res.status(504).json(unavailable);
    }
    // A road-less answer is a definite "no route", not an outage; the app must not show a route for it.
    if(body?.code==='NoRoute'||(response.ok&&body?.code==='Ok'&&Array.isArray(body.routes)&&!body.routes.length))
        return res.status(404).json({message:'No driving route was found between these points.'});
    if(!response.ok||body?.code!=='Ok'||!Array.isArray(body.routes)||!body.routes.length)return res.status(502).json(unavailable);
    res.set('Cache-Control','private, max-age=30').status(200).json(body);
}
