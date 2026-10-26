import { parseArgs } from 'node:util';
import { supabaseAdmin as supabase } from '../src/config/supabase.config.js';
import { parsePointCoordinates, resolveAddressDetails } from '../src/services/geocoding.service.js';

const { values: args } = parseArgs({
  options: {
    'dry-run': { type: 'boolean', default: false },
    confirm: { type: 'boolean', default: false },
    force: { type: 'boolean', default: false },
    limit: { type: 'string', default: '200' },
    help: { type: 'boolean', default: false },
  },
  allowPositionals: false,
});

if (args.help || (!args['dry-run'] && !args.confirm)) {
  console.log(`
Usage:
  node scripts/backfill-report-addresses.mjs --dry-run
  node scripts/backfill-report-addresses.mjs --confirm [--limit=500] [--force]

Options:
  --dry-run   Preview the resolved addresses and barangays without modifying the database
  --confirm   Persist the resolved street_address and barangay into public.reports
  --force     Re-evaluate ALL reports against building structures layer even if address is already present
  --limit     Maximum number of reports to backfill in this run (default: 200)
`);
  process.exit(0);
}

const isDryRun = args['dry-run'];
const isForce = args.force;
const maxLimit = parseInt(args.limit, 10) || 200;

console.log(`[Backfill] Starting report address backfill (Mode: ${isDryRun ? 'DRY-RUN' : 'CONFIRM'}, Force: ${isForce}, Limit: ${maxLimit})...`);

async function run() {
  let query = supabase
    .from('reports')
    .select('id, title, location, photo_lat, photo_lng, street_address, barangay, city')
    .order('created_at', { ascending: false })
    .limit(maxLimit);

  if (!isForce) {
    query = query.or('barangay.is.null,street_address.is.null');
  }

  const { data: reports, error } = await query;

  if (error) {
    console.error('[Backfill] Error fetching reports:', error.message);
    process.exit(1);
  }

  if (!reports || reports.length === 0) {
    console.log('[Backfill] No reports requiring address backfill. Everything is up to date!');
    process.exit(0);
  }

  console.log(`[Backfill] Found ${reports.length} report(s) needing address resolution.`);

  let successCount = 0;
  let failCount = 0;

  for (let i = 0; i < reports.length; i++) {
    const report = reports[i];
    let lat = null;
    let lon = null;

    const coords = parsePointCoordinates(report.location);
    if (coords) {
      lat = coords.lat;
      lon = coords.lon;
    } else if (report.photo_lat != null && report.photo_lng != null) {
      lat = parseFloat(report.photo_lat);
      lon = parseFloat(report.photo_lng);
    }

    if (lat == null || lon == null || isNaN(lat) || isNaN(lon)) {
      console.warn(`[Backfill] Report ${report.id} ("${report.title}") has no valid coordinates. Skipping.`);
      failCount++;
      continue;
    }

    // 1. Resolve Address Details (Street, Genuine Barangay, and City) via Geocoding service
    let resolvedStreet = report.street_address;
    let resolvedBarangay = report.barangay;
    let resolvedCity = report.city || 'Pasig City';

    try {
      const details = await resolveAddressDetails(lat, lon);
      if (details) {
        if (details.street_address) {
          resolvedStreet = details.street_address;
        }
        if (details.barangay) {
          resolvedBarangay = details.barangay;
        }
        if (details.city) {
          resolvedCity = details.city;
        }
      }
    } catch (err) {
      console.warn(`[Backfill] Geocoder error for ${report.id}:`, err.message);
    }

    // 2. If in Pasig and barangay is still missing, fallback to PostGIS get_report_barangay
    const isPasig = !resolvedCity || resolvedCity.toLowerCase().includes('pasig');
    if (isPasig && !resolvedBarangay) {
      try {
        const { data: bgyData, error: bgyErr } = await supabase.rpc('get_report_barangay', {
          lat,
          lng: lon
        });
        if (!bgyErr && bgyData && bgyData !== 'Pasig City') {
          resolvedBarangay = bgyData;
        }
      } catch (err) {
        console.warn(`[Backfill] Failed get_report_barangay RPC for ${report.id}:`, err.message);
      }
    }

    const isStreetChanged = resolvedStreet !== report.street_address;
    const isBarangayChanged = resolvedBarangay !== report.barangay;
    const isCityChanged = resolvedCity !== report.city;
    const isChanged = isStreetChanged || isBarangayChanged || isCityChanged;

    console.log(`[${i + 1}/${reports.length}] Report ${report.id.slice(0, 8)}:`);
    console.log(`   Pin: (${lat.toFixed(5)}, ${lon.toFixed(5)})`);
    console.log(`   Street:   ${resolvedStreet || '(none)'}${isStreetChanged && report.street_address ? ` (was: ${report.street_address})` : ''}`);
    console.log(`   Barangay: ${resolvedBarangay || 'Pasig City'}${isBarangayChanged && report.barangay ? ` (was: ${report.barangay})` : ''}`);
    console.log(`   City:     ${resolvedCity}${isCityChanged && report.city ? ` (was: ${report.city})` : ''}`);

    if (isForce && !isChanged) {
      console.log(`   ⚖️ Unchanged, skipping update.`);
      continue;
    }

    if (!isDryRun) {
      const { error: updateErr } = await supabase
        .from('reports')
        .update({
          street_address: resolvedStreet,
          barangay: resolvedBarangay || 'Pasig City',
          city: resolvedCity
        })
        .eq('id', report.id);

      if (updateErr) {
        console.error(`   ❌ Update failed: ${updateErr.message}`);
        failCount++;
      } else {
        console.log(`   ✅ Successfully updated.`);
        successCount++;
      }
    } else {
      console.log(`   [DRY-RUN] Would update to: "${resolvedStreet}, ${resolvedBarangay}"`);
      successCount++;
    }

    // Pause 300ms between records to be respectful to Photon geocoding service
    await new Promise(r => setTimeout(r, 300));
  }

  console.log('\n[Backfill Summary]');
  console.log(`Total processed: ${reports.length}`);
  console.log(`Resolved:        ${successCount}`);
  console.log(`Skipped/Failed:  ${failCount}`);
  if (isDryRun) {
    console.log(`\nNote: This was a DRY-RUN. To apply changes to the database, run:`);
    console.log(`node scripts/backfill-report-addresses.mjs --confirm`);
  }
}

run().catch(err => {
  console.error('[Backfill] Unexpected error:', err);
  process.exit(1);
});
