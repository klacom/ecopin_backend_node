import { parseArgs } from 'node:util';
import { readFileSync, existsSync } from 'node:fs';
import { supabaseAdmin as supabase } from '../src/config/supabase.config.js';

const { values: args } = parseArgs({
  options: {
    file: { type: 'string' },
    'dry-run': { type: 'boolean', default: false },
    limit: { type: 'string', default: '0' },
    all: { type: 'boolean', default: true },
    help: { type: 'boolean', default: false },
  },
  allowPositionals: false,
});

if (args.help || !args.file) {
  console.log(`
Usage:
  node scripts/import-pasig-buildings.mjs --file=/path/to/buildings.geojson [--dry-run] [--limit=0]

Options:
  --file      Path to a GeoJSON file exported from QGIS containing building footprints or address points.
  --dry-run   Preview records and geometries without writing to the database.
  --limit     Maximum number of features to import (default: 0 = unlimited / all features).
`);
  process.exit(0);
}

const isDryRun = args['dry-run'];
const parsedLimit = parseInt(args.limit, 10);
const maxLimit = (isNaN(parsedLimit) || parsedLimit <= 0) ? Infinity : parsedLimit;
const filePath = args.file;

if (!existsSync(filePath)) {
  console.error(`[Importer] Error: File not found at "${filePath}"`);
  process.exit(1);
}

console.log(`[Importer] Reading building data from "${filePath}" (Mode: ${isDryRun ? 'DRY-RUN' : 'LIVE'})...`);

let geojson = null;
try {
  const content = readFileSync(filePath, 'utf8');
  geojson = JSON.parse(content);
} catch (err) {
  console.error('[Importer] Failed to parse GeoJSON file:', err.message);
  process.exit(1);
}

const features = geojson.features || (geojson.type === 'Feature' ? [geojson] : []);
console.log(`[Importer] Found ${features.length} feature(s) in GeoJSON.`);

function extractProperties(props = {}) {
  const house_number = props['addr:housenumber'] || props.housenumber || props.HOUSE_NO || props.bldg_no || props.house_no || props.h_no || null;
  const street_name = props['addr:street'] || props.street || props.STREET_NAME || props.road || props.street_nam || null;
  const building_name = props.name || props.BLDG_NAME || (props.amenity ? `${props.amenity}` : null) || props.building_name || null;
  const barangay = props['addr:barangay'] || props.barangay || props.BARANGAY || props.bgy || null;

  return {
    house_number: house_number ? String(house_number).trim() : null,
    street_name: street_name ? String(street_name).trim() : null,
    building_name: building_name ? String(building_name).trim() : null,
    barangay: barangay ? String(barangay).trim() : null,
  };
}

async function run() {
  let imported = 0;
  let skipped = 0;
  const batchSize = 100;
  let batch = [];

  for (let i = 0; i < Math.min(features.length, maxLimit); i++) {
    const feat = features[i];
    if (!feat || !feat.geometry) {
      skipped++;
      continue;
    }

    const attr = extractProperties(feat.properties);
    if (!attr.street_name && !attr.building_name && !attr.house_number) {
      skipped++;
      continue;
    }

    // Calculate basic centroid if available
    let centroidLat = null;
    let centroidLng = null;
    if (feat.geometry.type === 'Point' && Array.isArray(feat.geometry.coordinates)) {
      centroidLng = feat.geometry.coordinates[0];
      centroidLat = feat.geometry.coordinates[1];
    }

    batch.push({
      house_number: attr.house_number,
      street_name: attr.street_name || null,
      barangay: attr.barangay,
      building_name: attr.building_name,
      source: 'qgis_geojson_import',
      centroid_lat: centroidLat,
      centroid_lng: centroidLng,
      boundary: feat.geometry, // Supabase PostGIS accepts GeoJSON objects directly
    });

    if (batch.length >= batchSize) {
      if (!isDryRun) {
        const { error } = await supabase.from('building_structures').insert(batch);
        if (error) {
          console.error(`[Importer] Error inserting batch:`, error.message);
        } else {
          imported += batch.length;
          console.log(`[Importer] Inserted ${imported} structures...`);
        }
      } else {
        imported += batch.length;
      }
      batch = [];
    }
  }

  // Insert remaining
  if (batch.length > 0) {
    if (!isDryRun) {
      const { error } = await supabase.from('building_structures').insert(batch);
      if (error) {
        console.error(`[Importer] Error inserting final batch:`, error.message);
      } else {
        imported += batch.length;
      }
    } else {
      imported += batch.length;
    }
  }

  console.log('\n[Importer Summary]');
  console.log(`Total features: ${features.length}`);
  console.log(`Imported:       ${imported}`);
  console.log(`Skipped:        ${skipped}`);
}

run().catch(err => {
  console.error('[Importer] Fatal error:', err);
  process.exit(1);
});
