const { createClient } = require('@supabase/supabase-js');

const supabaseUrl = 'https://wcruoyygungqxazdwhtv.supabase.co';
const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndjcnVveXlndW5ncXhhemR3aHR2Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3OTk4Mjc4NCwiZXhwIjoyMDk1NTU4Nzg0fQ.GwFiSXJpD-B5nP7lATUjTJVKJ-6NHbvpuMM37lUAuBw';
const supabase = createClient(supabaseUrl, supabaseKey);

async function test() {
  const { data, error } = await supabase
    .from('cleanup_tasks')
    .select('id, assigned_crew_ids')
    .limit(5);
    
  console.log('Sample tasks:', data);

  if (data && data.length > 0) {
    const taskWithCrew = data.find(t => t.assigned_crew_ids && t.assigned_crew_ids.length > 0);
    if (taskWithCrew) {
      const crewId = taskWithCrew.assigned_crew_ids[0];
      console.log('Testing contains with crewId:', crewId);
      
      const { data: d1, error: e1 } = await supabase
        .from('cleanup_tasks')
        .select('id, assigned_crew_ids')
        .contains('assigned_crew_ids', [crewId]);
        
      console.log('Result of .contains(..., [id]):', d1?.length, 'error:', e1);
      
      const { data: d2, error: e2 } = await supabase
        .from('cleanup_tasks')
        .select('id, assigned_crew_ids')
        .contains('assigned_crew_ids', JSON.stringify([crewId]));
        
      console.log('Result of .contains(..., JSON.stringify([id])):', d2?.length, 'error:', e2);
    }
  }
}
test();
