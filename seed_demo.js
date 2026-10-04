import fs from 'fs';
import path from 'path';
import 'dotenv/config';
import { supabaseAdmin } from './src/config/supabase.config.js';
import { uploadFromBuffer } from './src/services/cloudinary.service.js';

const IMAGES_DIR = 'C:\\dev\\sample_images';
const NUM_REPORTS = 30;
const BOUNDS = {
  latMin: 14.5000,
  latMax: 14.7000,
  lngMin: 120.9000,
  lngMax: 121.1000
};

// Random helpers
const randomFloat = (min, max) => Math.random() * (max - min) + min;
const randomInt = (min, max) => Math.floor(Math.random() * (max - min + 1)) + min;
const randomElement = (arr) => arr[Math.floor(Math.random() * arr.length)];

async function clearOldData() {
  console.log('Clearing old data (reports, clusters, cleanup_tasks, optimization_runs, routes)...');
  
  const tables = [
    'fc_conflict_audit',
    'fc_operation_log',
    'dispatch_plan_items',
    'dispatch_plans',
    'sync_conflicts',
    'route_waypoints',
    'crew_routes',
    'optimization_runs',
    'optimization_settings',
    'reports',
    'cleanup_tasks',
    'clusters',
    'hotspot_predictions'
  ];

  for (const table of tables) {
    console.log(`Clearing ${table}...`);
    const { error } = await supabaseAdmin.from(table).delete().neq('id', '00000000-0000-0000-0000-000000000000');
    if (error && error.code !== 'PGRST116') {
      console.warn(`Error clearing ${table}:`, error.message);
    }
  }
  console.log('Data cleared successfully.');
}

async function getRandomUser() {
  const { data, error } = await supabaseAdmin.from('profiles').select('id').limit(5);
  if (error || !data || data.length === 0) {
    throw new Error('No users found in profiles to assign reports to.');
  }
  return randomElement(data).id;
}

async function uploadImage(imageName) {
  const imagePath = path.join(IMAGES_DIR, imageName);
  const buffer = fs.readFileSync(imagePath);
  console.log(`Uploading ${imageName}...`);
  try {
    const result = await uploadFromBuffer(buffer, 'ecopin_demo', `demo_${Date.now()}_${randomInt(1000, 9999)}`);
    return result.secure_url;
  } catch (err) {
    console.error(`Failed to upload ${imageName}`, err);
    return null;
  }
}

async function seedData() {
  try {
    // 1. Clear old data
    await clearOldData();

    if (process.argv.includes('--clear-only')) {
      console.log('Clear only mode finished.');
      return;
    }

    // 2. Read sample images
    let files = fs.readdirSync(IMAGES_DIR).filter(f => f.endsWith('.jpg') || f.endsWith('.png'));
    if (files.length === 0) {
      throw new Error('No images found in ' + IMAGES_DIR);
    }
    
    // Shuffle and pick
    files = files.sort(() => 0.5 - Math.random()).slice(0, NUM_REPORTS);
    
    const userId = await getRandomUser();
    const reports = [];

    console.log(`Seeding ${files.length} reports...`);

    for (const file of files) {
      const url = await uploadImage(file);
      if (!url) continue;

      const lat = randomFloat(BOUNDS.latMin, BOUNDS.latMax);
      const lng = randomFloat(BOUNDS.lngMin, BOUNDS.lngMax);

      const issueTypes = ['waste', 'pollution'];
      
      const report = {
        user_id: userId,
        title: `Environmental Issue - ${randomElement(['Roadside', 'Park', 'Sidewalk', 'Alley'])}`,
        description: 'Dummy data for professor demo.',
        issue_type: randomElement(issueTypes),
        location: `POINT(${lng} ${lat})`,
        validation_status: 'approved',
        status: 'unresolved',
        before_photo_url: url,
        ml_predicted_class: 'trash',
        ml_confidence: randomFloat(0.7, 0.99),
        ra9003_category: 'solid',
        severity_score: randomInt(0, 100),
        urgency_score: randomInt(1, 3)
      };
      reports.push(report);
    }

    const { data, error } = await supabaseAdmin.from('reports').insert(reports).select('id');
    if (error) {
      console.error('Error inserting reports:', error);
    } else {
      console.log(`Successfully inserted ${data.length} reports.`);
    }

  } catch (e) {
    console.error('Seeding failed:', e);
  }
}

seedData();
