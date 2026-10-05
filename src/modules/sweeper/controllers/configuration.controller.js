import { 
  getSlaThreshold, 
  getShiftDuration, 
  getAllWorkTimes, 
  updateSlaThreshold, 
  updateShiftDuration, 
  updateWorkTime 
} from '../services/configuration.service.js';

export async function getConfig(req, res) {
  // Assuming req.user contains the authenticated user details
  if (req.user?.role !== 'admin' && req.user?.role !== 'system_administrator') {
    return res.status(403).json({ error: 'Access denied: Admin role required' });
  }

  try {
    const [slaThreshold, shiftDuration, workTimes] = await Promise.all([
      getSlaThreshold(),
      getShiftDuration(),
      getAllWorkTimes()
    ]);

    res.json({
      slaThreshold,
      shiftDuration,
      workTimes
    });
  } catch (error) {
    console.error('Error fetching configuration:', error);
    res.status(500).json({ error: 'Failed to fetch configuration' });
  }
}

export async function updateSlaThresholdConfig(req, res) {
  if (req.user?.role !== 'admin' && req.user?.role !== 'system_administrator') {
    return res.status(403).json({ error: 'Access denied: Admin role required' });
  }

  const { hours } = req.body;
  const adminId = req.user?.id || 'admin';

  if (!hours || typeof hours !== 'number' || hours < 1 || hours > 168) {
    return res.status(400).json({ error: 'SLA threshold must be a number between 1 and 168 hours' });
  }

  try {
    const currentHours = await getSlaThreshold();
    const difference = Math.abs(currentHours - hours);
    const percentChange = (difference / currentHours) * 100;
    
    // For large changes (> 25%), we expect a confirmation flag in the request
    if (percentChange > 25 && !req.body.confirmLargeChange) {
      return res.status(400).json({ 
        error: 'Large configuration change detected (>25%). Please confirm.',
        requiresConfirmation: true,
        percentChange 
      });
    }

    const newHours = await updateSlaThreshold(hours, adminId);
    res.json({ message: 'SLA threshold updated successfully', slaThreshold: newHours });
  } catch (error) {
    console.error('Error updating SLA threshold:', error);
    res.status(500).json({ error: error.message || 'Failed to update SLA threshold' });
  }
}

export async function updateShiftDurationConfig(req, res) {
  if (req.user?.role !== 'admin' && req.user?.role !== 'system_administrator') {
    return res.status(403).json({ error: 'Access denied: Admin role required' });
  }

  const { hours } = req.body;
  const adminId = req.user?.id || 'admin';

  try {
    const newHours = await updateShiftDuration(null, hours, adminId);
    res.json({ message: 'Shift duration updated successfully', shiftDuration: newHours });
  } catch (error) {
    console.error('Error updating shift duration:', error);
    res.status(400).json({ error: error.message || 'Failed to update shift duration' });
  }
}

export async function updateWorkTimeConfig(req, res) {
  if (req.user?.role !== 'admin' && req.user?.role !== 'system_administrator') {
    return res.status(403).json({ error: 'Access denied: Admin role required' });
  }

  const { reportType, minutes } = req.body;
  const adminId = req.user?.id || 'admin';

  if (!reportType) {
    return res.status(400).json({ error: 'Report type is required' });
  }

  const validReportTypes = ['waste', 'flooding', 'pollution', 'infrastructure', 'illegal_logging', 'pending', 'others'];
  if (!validReportTypes.includes(reportType)) {
    return res.status(400).json({ error: `Invalid report type. Must be one of: ${validReportTypes.join(', ')}` });
  }

  try {
    const newMinutes = await updateWorkTime(reportType, minutes, adminId);
    res.json({ message: 'Work time updated successfully', reportType, workTimeMinutes: newMinutes });
  } catch (error) {
    console.error(`Error updating work time for ${reportType}:`, error);
    res.status(400).json({ error: error.message || 'Failed to update work time' });
  }
}
