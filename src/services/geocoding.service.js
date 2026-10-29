import fetch from 'node-fetch';
import { supabaseAdmin } from '../config/supabase.config.js';

const geocodeCache = new Map();
const MAX_CACHE_SIZE = 1000;

export {OFFICIAL_PASIG_BARANGAYS} from './pasig-barangay-catalog.js';
import {OFFICIAL_PASIG_BARANGAYS} from './pasig-barangay-catalog.js';
import {applyBarangayResolution} from './barangay-resolution.service.js';

/**
 * Parses coordinates from either 'POINT(lon lat)' string or GeoJSON Point object.
 */
export const parsePointCoordinates = (locationInput) => {
    if (!locationInput) return null;

    let lon, lat;
    if (typeof locationInput === 'string') {
        const trimmed = locationInput.trim();
        // 1. Text format: POINT(lon lat)
        const match = trimmed.match(/POINT\s*\(([-.\d]+)\s+([-.\d]+)\)/i);
        if (match) {
            lon = parseFloat(match[1]);
            lat = parseFloat(match[2]);
        }
        // 2. PostGIS EWKB / WKB hex string (e.g. 0101000020E6100000...)
        else if (/^[0-9a-fA-F]{42,50}$/.test(trimmed)) {
            try {
                const buf = Buffer.from(trimmed, 'hex');
                const isLittleEndian = buf.readUInt8(0) === 1;
                const geomType = isLittleEndian ? buf.readUInt32LE(1) : buf.readUInt32BE(1);
                const hasSrid = (geomType & 0x20000000) !== 0;
                const offset = hasSrid ? 9 : 5;

                lon = isLittleEndian ? buf.readDoubleLE(offset) : buf.readDoubleBE(offset);
                lat = isLittleEndian ? buf.readDoubleLE(offset + 8) : buf.readDoubleBE(offset + 8);
            } catch (err) {
                return null;
            }
        } else {
            return null;
        }
    } else if (typeof locationInput === 'object' && locationInput.type === 'Point' && Array.isArray(locationInput.coordinates)) {
        lon = parseFloat(locationInput.coordinates[0]);
        lat = parseFloat(locationInput.coordinates[1]);
    } else if (typeof locationInput === 'object' && locationInput.latitude != null && locationInput.longitude != null) {
        lat = parseFloat(locationInput.latitude);
        lon = parseFloat(locationInput.longitude);
    } else {
        return null;
    }

    if (!Number.isFinite(lat) || !Number.isFinite(lon) || Math.abs(lat)>90 || Math.abs(lon)>180) return null;
    return { lat, lon };
};

/**
 * Resolves detailed address components (street, barangay, city) using ArcGIS or OpenStreetMap.
 * @param {number} lat
 * @param {number} lon
 * @returns {Promise<{ street_address: string|null, barangay: string|null, city: string, display_name: string|null }>}
 */
export const resolveAddressDetails = async (lat, lon) => {
    if (!Number.isFinite(lat) || !Number.isFinite(lon) || Math.abs(lat)>90 || Math.abs(lon)>180) {
        return {street_address:null,barangay:null,city:null,display_name:null,barangay_resolution_status:'invalid_coordinates',barangay_candidates:[]};
    }

    const cacheKey = `details:${lat},${lon}`;
    if (geocodeCache.has(cacheKey)) {
        return applyBarangayResolution(geocodeCache.get(cacheKey),lat,lon);
    }

    let result = {
        street_address: null,
        barangay: null,
        city: 'Pasig City',
        display_name: null
    };

    // 0. TIER 0: Local PostGIS Building & Structure Spatial Matching (< 5ms, 100% offline)
    let tier0Landmark = null;
    try {
        const { data: structData, error: structErr } = await supabaseAdmin.rpc('get_structure_address', {
            lat,
            lng: lon,
            buffer_meters: 25.0
        });

        if (!structErr && Array.isArray(structData) && structData.length > 0) {
            const match = structData[0];
            const houseNo = match.house_number?.trim();
            const street = match.street_name?.trim();
            const bldgName = match.building_name?.trim();

            if (houseNo && street && bldgName) {
                result.street_address = `${houseNo} ${street} (${bldgName})`;
            } else if (houseNo && street) {
                result.street_address = `${houseNo} ${street}`;
            } else if (street && bldgName) {
                result.street_address = `${street} (near ${bldgName})`;
            } else if (street) {
                result.street_address = street;
            } else if (bldgName) {
                tier0Landmark = bldgName;
            }

            if (match.barangay?.trim() && OFFICIAL_PASIG_BARANGAYS.has(match.barangay.trim())) {
                result.barangay = match.barangay.trim();
                result.city = 'Pasig City';
            }

        }
    } catch (_) {
        // Table or function not yet created or empty; smoothly fallback to Photon/OSM
    }

    // 1. Try ArcGIS if API key is configured
    const arcgisApiKey = process.env.ARCGIS_API_KEY;
    if (arcgisApiKey) {
        try {
            const arcgisUrl = `https://geocode-api.arcgis.com/arcgis/rest/services/World/GeocodeServer/reverseGeocode?location=${lon},${lat}&f=json&token=${arcgisApiKey}`;
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), 3500);

            const res = await fetch(arcgisUrl, { signal: controller.signal });
            clearTimeout(timer);

            if (res.ok) {
                const data = await res.json();
                if (data?.address) {
                    const addr = data.address;
                    const street = addr.Address?.trim() || null;
                    const place = addr.PlaceName?.trim() || addr.ShortLabel?.trim() || null;

                    if (street && place && street !== place && !place.includes(street)) {
                        result.street_address = `${street} (${place})`;
                    } else {
                        const baseStreet = addr.ShortLabel || addr.Address || addr.Match_addr?.split(',')[0] || null;
                        if (baseStreet && tier0Landmark && !baseStreet.includes(tier0Landmark)) {
                            result.street_address = `${baseStreet} (${tier0Landmark})`;
                        } else {
                            result.street_address = baseStreet;
                        }
                    }

                    result.barangay = addr.Neighborhood || addr.District || null;
                    result.city = addr.City || 'Pasig City';
                    result.display_name = addr.Match_addr || null;
                }
            }
        } catch (err) {
            console.warn('[GeocodingService] ArcGIS lookup warning:', err.message);
        }
    }

    // 2. Try Photon by Komoot (Free OpenStreetMap high-capacity reverse geocoding)
    if (!result.street_address) {
        try {
            const photonUrl = `https://photon.komoot.io/reverse?lat=${lat}&lon=${lon}`;
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), 3500);

            const res = await fetch(photonUrl, {
                signal: controller.signal,
                headers: {
                    'User-Agent': process.env.GEOCODING_USER_AGENT || 'EcoPinPasigCivic/1.0 (contact@ecopin.local)',
                    'Accept-Language': 'en'
                }
            });
            clearTimeout(timer);

            if (res.ok) {
                const data = await res.json();
                const props = data?.features?.[0]?.properties;
                if (props) {
                    const street = props.street || (props.type === 'street' ? props.name : null);
                    const houseNumber = props.housenumber;
                    const landmark = tier0Landmark || null;

                    if (houseNumber && street && landmark) {
                        result.street_address = `${houseNumber} ${street} (near ${landmark})`;
                    } else if (houseNumber && street) {
                        result.street_address = `${houseNumber} ${street}`;
                    } else if (street && landmark) {
                        result.street_address = `${street} (near ${landmark})`;
                    } else if (street) {
                        result.street_address = street;
                    } else if (landmark) {
                        result.street_address = landmark;
                    }

                    if (!result.barangay && (props.locality || props.district)) {
                        result.barangay = props.locality || props.district;
                    }
                    if (props.city) {
                        result.city = props.city;
                    }
                    result.display_name = [result.street_address, result.barangay, result.city].filter(Boolean).join(', ');
                }
            }
        } catch (err) {
            console.warn('[GeocodingService] Photon lookup warning:', err.message);
        }
    }

    // 3. Fallback to OpenStreetMap Nominatim if needed
    if (!result.street_address) {
        try {
            const osmUrl = `https://nominatim.openstreetmap.org/reverse?format=json&lat=${lat}&lon=${lon}&zoom=18&addressdetails=1`;
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), 4000);

            let res = await fetch(osmUrl, {
                signal: controller.signal,
                headers: {
                    'User-Agent': process.env.GEOCODING_USER_AGENT || 'EcoPinPasigCivic/1.0 (contact@ecopin.local)',
                    'Accept-Language': 'en'
                }
            });
            clearTimeout(timer);

            if (res.ok) {
                const data = await res.json();
                const address = data?.address || {};

                // Road identifier
                const roadPart = address.road || address.pedestrian || address.highway || address.path ||
                                 address.street || address.residential || address.footway || address.alley ||
                                 address.lane || address.service || address.cycleway || address.bridge;

                // Explicit numeric door/house number ONLY
                const houseNumber = address.house_number ? String(address.house_number).trim() : null;

                // Institutional venue or establishment name (never glued directly in front of a street like a house number)
                const venueName = address.building || address.amenity || address.shop || address.office ||
                                  address.commercial || address.leisure || address.tourism || address.industrial || null;

                const landmark = tier0Landmark || ((data.name && data.name !== roadPart && data.name !== houseNumber)
                                 ? data.name
                                 : (venueName && venueName !== roadPart ? venueName : null));

                if (houseNumber && roadPart && landmark && landmark !== houseNumber) {
                    result.street_address = `${houseNumber} ${roadPart} (${landmark})`;
                } else if (houseNumber && roadPart) {
                    result.street_address = `${houseNumber} ${roadPart}`;
                } else if (roadPart && landmark) {
                    result.street_address = `${roadPart} (near ${landmark})`;
                } else if (roadPart) {
                    result.street_address = roadPart;
                } else if (landmark) {
                    result.street_address = landmark;
                }

                // Candidate barangay from OSM quarter, suburb, village, or neighbourhood
                const candidateBgy = address.quarter || address.suburb || address.village || address.neighbourhood || null;
                if (candidateBgy && !result.barangay) {
                    result.barangay = candidateBgy;
                }

                const detectedCity = address.city || address.town || address.municipality || null;
                if (detectedCity) {
                    result.city = detectedCity;
                }
                result.display_name = data.display_name || null;
            }
        } catch (err) {
            console.warn('[GeocodingService] Nominatim lookup warning:', err.message);
        }
    }

    if (!result.street_address && tier0Landmark) {
        result.street_address = tier0Landmark;
    }

    // Administrative assignment always comes from polygons, including building/cache hits.
    result = await applyBarangayResolution(result,lat,lon);

    // Only cache successful results so temporary network/rate-limit errors can be retried later
    if ((result.street_address || result.barangay) && result.barangay_resolution_status !== 'unavailable') {
        if (geocodeCache.size >= MAX_CACHE_SIZE) {
            const firstKey = geocodeCache.keys().next().value;
            geocodeCache.delete(firstKey);
        }
        geocodeCache.set(cacheKey, result);
    }

    return result;
};

/**
 * Backward-compatible reverseGeocode returning string display_name.
 */
export const reverseGeocode = async (locationStr) => {
    const coords = parsePointCoordinates(locationStr);
    if (!coords) return null;

    const details = await resolveAddressDetails(coords.lat, coords.lon);
    const address = details.display_name || details.street_address || null;

    return address;
};

export const extractLocationStr = (task) => {
    if (!task) return null;
    return task.location || task.clusters?.center || (task.reports?.[0]?.location);
};
