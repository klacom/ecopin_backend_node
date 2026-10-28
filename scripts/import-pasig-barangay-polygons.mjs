import fetch from 'node-fetch';
import { supabaseAdmin as supabase } from '../src/config/supabase.config.js';

const PASIG_BARANGAY_GEOJSON_URL = 'https://raw.githubusercontent.com/faeldon/philippines-json-maps/master/latest/geojson/municities/medres/bgysubmuns-municity-1381200000.0.01.json';

async function run() {
  console.log('[Polygon Importer] Fetching official Pasig City 30 barangay boundaries...');
  const res = await fetch(PASIG_BARANGAY_GEOJSON_URL);
  if (!res.ok) {
    throw new Error(`Failed to download GeoJSON: ${res.statusText}`);
  }

  const geojson = await res.json();
  const features = geojson.features || [];
  console.log(`[Polygon Importer] Downloaded ${features.length} barangay boundaries.`);

  // Clear existing barangay spatial zones if any
  const { error: delErr } = await supabase
    .from('spatial_zones')
    .delete()
    .eq('zone_type', 'barangay');

  if (delErr) {
    console.warn('[Polygon Importer] Delete warning:', delErr.message);
  }

  const rows = [];
  for (const feat of features) {
    const name = feat.properties.adm4_en || feat.properties.NAME_4;
    if (!name || !feat.geometry) continue;

    // Compute basic centroid from bbox or coordinates
    let sumLat = 0, sumLng = 0, count = 0;
    const geom = feat.geometry;
    const rings = geom.type === 'Polygon' ? geom.coordinates : (geom.type === 'MultiPolygon' ? geom.coordinates.flat() : []);
    for (const ring of rings) {
      for (const pt of ring) {
        sumLng += pt[0];
        sumLat += pt[1];
        count++;
      }
    }
    const cLat = count > 0 ? (sumLat / count) : 14.5761;
    const cLng = count > 0 ? (sumLng / count) : 121.0851;

    rows.push({
      id: `barangay_${name.toLowerCase().replace(/[^a-z0-9]+/g, '_')}`,
      zone_name: name,
      zone_type: 'barangay',
      boundary_geojson: feat.geometry,
      centroid_lat: cLat,
      centroid_lng: cLng
    });
  }

  console.log(`[Polygon Importer] Inserting ${rows.length} official barangay polygons into public.spatial_zones...`);
  const { error: insErr } = await supabase
    .from('spatial_zones')
    .upsert(rows, { onConflict: 'id' });

  if (insErr) {
    console.error('[Polygon Importer] Error inserting polygons:', insErr.message);
    process.exit(1);
  }

  console.log('[Polygon Importer] Successfully loaded 30 official Pasig City barangay polygons into PostGIS!');
}

run().catch(err => {
  console.error('[Polygon Importer] Fatal error:', err);
  process.exit(1);
});
