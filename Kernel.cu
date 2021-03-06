﻿#include "Kernel.cuh"

// __device__ __constant__ int sens_num = 48;

__device__ int* no_sensors;
__device__ int* no_hits;
__device__ int* sensor_Zs;
__device__ int* sensor_hitStarts;
__device__ int* sensor_hitNums;
__device__ unsigned int* hit_IDs;
__device__ float* hit_Xs;
__device__ float* hit_Ys;
__device__ float* hit_Zs;

__device__ int* prevs;
__device__ int* nexts;


__global__ void prepareData(char* input, int* _prevs, int* _nexts, bool* track_holders) {
  no_sensors = (int*) &input[0];
  no_hits = (int*) (no_sensors + 1);
  sensor_Zs = (int*) (no_hits + 1);
  sensor_hitStarts = (int*) (sensor_Zs + no_sensors[0]);
  sensor_hitNums = (int*) (sensor_hitStarts + no_sensors[0]);
  hit_IDs = (unsigned int*) (sensor_hitNums + no_sensors[0]);
  hit_Xs = (float*) (hit_IDs + no_hits[0]);
  hit_Ys = (float*) (hit_Xs + no_hits[0]);
  hit_Zs = (float*) (hit_Ys + no_hits[0]);

  prevs = _prevs;
  nexts = _nexts;

  for(int i=0; i<MAX_TRACKS; ++i) {
    track_holders[i] = false;
  }
}

/** fitHits, gives the fit between h0 and h1.

The accept condition requires dxmax and dymax to be in a range.

The fit (d1) depends on the distance of the tracklet to <0,0,0>.
*/
__device__ float fitHits(Hit& h0, Hit& h1, Hit &h2) {
  // Max dx, dy permissible over next hit

  // TODO: This can go outside this function (only calc once per pair
  // of sensors). Also, it could only be calculated on best fitting distance d1.
  const float h_dist = fabs((float)( h1.z - h0.z ));
  float dxmax = PARAM_MAXXSLOPE * h_dist;
  float dymax = PARAM_MAXYSLOPE * h_dist;
  
  bool accept_condition = fabs(h1.x - h0.x) < dxmax &&
              fabs(h1.y - h0.y) < dymax;

  /*float dxmax = PARAM_MAXXSLOPE * fabs((float)( s1.z - s0.z ));
  float dymax = PARAM_MAXYSLOPE * fabs((float)( s1.z - s0.z ));*/
  
  // Distance to <0,0,0> in its XY plane.
  /*float t = - s0.z / (s1.z - s0.z);
  float x = h0.x + t * (h1.x - h0.x);
  float y = h0.y + t * (h1.y - h0.y);
  float d1 = sqrtf( powf( (float) (x), 2.0f) + 
        powf( (float) (y), 2.0f));*/

  // Distance between the hits.
  // float d1 = sqrtf( powf( (float) (h1.x - h0.x), 2.0f) + 
  //          powf( (float) (h1.y - h0.y), 2.0f));

  // Distance between line <h0,h1> and h2 in XY plane (s2.z)
  // float t = s2.z - s0.z / (s1.z - s0.z);
  // float x = h0.x + t * (h1.x - h0.x);
  // float y = h0.y + t * (h1.y - h0.y);
  // float d1 = sqrtf( powf( (float) (x - h2.x), 2.0f) + 
  //      powf( (float) (y - h2.y), 2.0f));
  // accept_condition &= (fabs(x - h2.x) < PARAM_TOLERANCE);

  // Require chi2 of third hit below the threshold
  // float t = ((float) (s2.z - s0.z)) / ((float) (s1.z - s0.z));

  // First approximation -
  // With the sensor z, instead of the hit z
  float z2_tz = ((float) h2.z - h0.z) / ((float) (h1.z - h0.z));
  float x = h0.x + (h1.x - h0.x) * z2_tz;
  float y = h0.y + (h1.y - h0.y) * z2_tz;

  float dx = x - h2.x;
  float dy = y - h2.y;
  float chi2 = dx * dx * PARAM_W + dy * dy * PARAM_W;
  // accept_condition &= chi2 < PARAM_MAXCHI2; // No need for this

  return accept_condition * chi2 + !accept_condition * MAX_FLOAT;
}

// Deprecated
__device__ float fitHitToTrack(Track& t, Hit& h1, Sensor& s1) {
  // tolerance
  float x_prediction = t.x0 + t.tx * s1.z;
  bool tol_condition = fabs(x_prediction - h1.x) < PARAM_TOLERANCE;

  // chi2 of hit (taken out from function for efficiency)
  float dx = x_prediction - h1.x;
  float dy = (t.y0 + t.ty * s1.z) - h1.y;
  float chi2 = dx * dx * PARAM_W + dy * dy * PARAM_W;

  // TODO: The check for chi2_condition can totally be done after this call
  bool chi2_condition = chi2 < PARAM_MAXCHI2;
  
  return tol_condition * chi2_condition * chi2 + (!tol_condition || !chi2_condition) * MAX_FLOAT;
}

/**
 * @brief Fits hits to tracks.
 * @details In case the tolerances constraints are met,
 *          returns the chi2 weight of the track. Otherwise,
 *          returns MAX_FLOAT.
 * 
 * @param tx 
 * @param ty 
 * @param h0 
 * @param t 
 * @param h2 
 * @return 
 */
__device__ float fitHitToTrack(const float tx, const float ty, const Hit& h0, const Track& t, const Hit& h2){
  // tolerances
  const float dz = h2.z - h0.z;
  const float x_prediction = h0.x + tx * dz;
  const float dx = fabs(x_prediction - h2.x);
  const bool tolx_condition = dx < PARAM_TOLERANCE;

  const float y_prediction = h0.y + ty * dz;
  const float dy = fabs(y_prediction - h2.y);
  const bool toly_condition = dy < PARAM_TOLERANCE;

  // chi2 - how good is this fit
  const float chi2 = dx * dx * PARAM_W + dy * dy * PARAM_W;
  const bool condition = tolx_condition && toly_condition;

  return condition * chi2 + !condition * MAX_FLOAT;
}

// Create track
__device__ void acceptTrack(Track& t, TrackFit& fit, Hit& h0, Hit& h1, int h0_num, int h1_num) {
  const float wz = PARAM_W * h0.z;

  fit.s0 = PARAM_W;
  fit.sx = PARAM_W * h0.x;
  fit.sz = wz;
  fit.sxz = wz * h0.x;
  fit.sz2 = wz * h0.z;

  fit.u0 = PARAM_W;
  fit.uy = PARAM_W * h0.y;
  fit.uz = wz;
  fit.uyz = wz * h0.y;
  fit.uz2 = wz * h0.z;

  t.hitsNum = 1;
  t.hits[0] = h0_num;

  // note: This could be done here (inlined)
  updateTrack(t, fit, h1, h1_num);
}

// Update track
__device__ void updateTrack(Track& t, TrackFit& fit, Hit& h1, int h1_num) {
  const float wz = PARAM_W * h1.z;

  fit.s0 += PARAM_W;
  fit.sx += PARAM_W * h1.x;
  fit.sz += wz;
  fit.sxz += wz * h1.x;
  fit.sz2 += wz * h1.z;

  fit.u0 += PARAM_W;
  fit.uy += PARAM_W * h1.y;
  fit.uz += wz;
  fit.uyz += wz * h1.y;
  fit.uz2 += wz * h1.z;

  t.hits[t.hitsNum] = h1_num;
  t.hitsNum++;

  updateTrackCoords(t, fit);
}

// TODO: Check this function
__device__ void updateTrackCoords (Track& t, TrackFit& fit) {
  float den = ( fit.sz2 * fit.s0 - fit.sz * fit.sz );
  if ( fabs(den) < 10e-10 ) den = 1.f;
  t.tx     = ( fit.sxz * fit.s0  - fit.sx  * fit.sz ) / den;
  t.x0     = ( fit.sx  * fit.sz2 - fit.sxz * fit.sz ) / den;

  den = ( fit.uz2 * fit.u0 - fit.uz * fit.uz );
  if ( fabs(den) < 10e-10 ) den = 1.f;
  t.ty     = ( fit.uyz * fit.u0  - fit.uy  * fit.uz ) / den;
  t.y0     = ( fit.uy  * fit.uz2 - fit.uyz * fit.uz ) / den;
}

/** Simple implementation of the Kalman Filter selection on the GPU (step 4).

Will rely on pre-processing for selecting next-hits for each hit.

Implementation,
- Perform implementation searching on all hits for each sensor

The algorithm has two parts:
- Track creation (two hits)
- Track following (consecutive sensors)


Optimizations,
- Optimize with shared memory
- Optimize further with pre-processing

Then there must be a post-processing, which selects the
best tracks based on (as per the conversation with David):
- length
- chi2

For this, simply use the table with all created tracks (postProcess):

#track, h0, h1, h2, h3, ..., hn, length, chi2

*/

__global__ void gpuKalman(Track* tracks, bool* track_holders) {
  Track t;
  TrackFit tfit;
  Sensor s0, s1, s2;
  Hit h0, h1, h2;

  float fit, best_fit;
  bool fit_is_better, accept_track;
  int first_hit, best_hit_h1, best_hit_h2;

  int first_sensor = (51 - blockIdx.x);
  int second_sensor = first_sensor - 2;
  int third_sensor  = first_sensor - 4;

  s0.hitStart = sensor_hitStarts[first_sensor];
  s0.hitNums = sensor_hitNums[first_sensor];
  // s0.z = sensor_Zs[first_sensor];


  if(third_sensor >= 0) {
    s1.hitStart = sensor_hitStarts[second_sensor];
    s1.hitNums = sensor_hitNums[second_sensor];
    // s1.z = sensor_Zs[second_sensor];

    // Iterate in all hits for current sensor
    for(int i=0; i<int(ceilf( ((float) s0.hitNums) / blockDim.x)); ++i) {
      first_hit = blockDim.x * i + threadIdx.x;

      if(first_hit < s0.hitNums) {
        const int h0_index = s0.hitStart + first_hit;
        h0.x = hit_Xs[h0_index];
        h0.y = hit_Ys[h0_index];
        h0.z = hit_Zs[h0_index];

        // Initialize track
        for(int j=0; j<MAX_TRACK_SIZE; ++j) {
          t.hits[j] = -1;
        }
    
        // TRACK CREATION
        best_fit = MAX_FLOAT;
        best_hit_h1 = -1;
        best_hit_h2 = -1;
        for(int j=0; j<s1.hitNums; ++j) {
          const int h1_index = s1.hitStart + j;
          h1.x = hit_Xs[h1_index];
          h1.y = hit_Ys[h1_index];
          h1.z = hit_Zs[h1_index];

          s2.hitStart = sensor_hitStarts[third_sensor];
          s2.hitNums = sensor_hitNums[third_sensor];
          // s2.z = sensor_Zs[third_sensor];

          // Iterate in the third! list of hits
          for(int k=0; k<s2.hitNums; ++k) {
            const int h2_index = s2.hitStart + k;
            h2.x = hit_Xs[h2_index];
            h2.y = hit_Ys[h2_index];
            h2.z = hit_Zs[h2_index];

            fit = fitHits(h0, h1, h2);
            fit_is_better = fit < best_fit;

            best_fit = fit_is_better * fit + !fit_is_better * best_fit;
            best_hit_h1 = fit_is_better * (h1_index) + !fit_is_better * best_hit_h1;
            best_hit_h2 = fit_is_better * (h2_index) + !fit_is_better * best_hit_h2;
          }
        }

        // We have a best fit! - haven't we?
        accept_track = best_fit != MAX_FLOAT;

        // For those who have tracks, we go on
        if(accept_track) {
          // Reload h1 and h2
          h1.x = hit_Xs[best_hit_h1];
          h1.y = hit_Ys[best_hit_h1];
          h1.z = hit_Zs[best_hit_h1];

          h2.x = hit_Xs[best_hit_h2];
          h2.y = hit_Ys[best_hit_h2];
          h2.z = hit_Zs[best_hit_h2];

          // Fill in t (ONLY in case the best fit is acceptable)
          acceptTrack(t, tfit, h0, h1, s0.hitStart + first_hit, best_hit_h1);
          updateTrack(t, tfit, h2, best_hit_h2);

          // TRACK FOLLOWING
          int f_next_sensor = third_sensor - 2;
          while(f_next_sensor >= 0) {
            // Interchange hits
            // h0 and h1 host the last two hits found,
            // and we search for h2
            h0 = h1;
            h1 = h2;

            // Go to following sensor
            s2.hitStart = sensor_hitStarts[f_next_sensor];
            s2.hitNums = sensor_hitNums[f_next_sensor];
            // s2.z = sensor_Zs[f_next_sensor];

            // Line calculations
            const float td = 1.0f / (h1.z - h0.z);
            const float txn = (h1.x - h0.x);
            const float tyn = (h1.y - h0.y);
            const float tx = txn * td;
            const float ty = tyn * td;

            best_fit = MAX_FLOAT;
            for(int k=0; k<s2.hitNums; ++k) {
              const int h2_index = s2.hitStart + k;
              h2.x = hit_Xs[h2_index];
              h2.y = hit_Ys[h2_index];
              h2.z = hit_Zs[h2_index];

              fit = fitHitToTrack(tx, ty, h0, t, h2);
              fit_is_better = fit < best_fit;

              best_fit = fit_is_better * fit + !fit_is_better * best_fit;
              best_hit_h2 = fit_is_better * h2_index + !fit_is_better * best_hit_h2;
            }

            // We have a best fit!
            // Fill in t, ONLY in case the best fit is acceptable

            // TODO: Maybe try to do this more "parallel"
            if(best_fit != MAX_FLOAT) {
              // Reload h2
              h2.x = hit_Xs[best_hit_h2];
              h2.y = hit_Ys[best_hit_h2];
              h2.z = hit_Zs[best_hit_h2];
              
              updateTrack(t, tfit, h2, best_hit_h2);
            }

            f_next_sensor -= 2;
          }
        }

        // If it's a track, write it to memory
        // If track_holders is already initialized, we can rewrite this
        track_holders[s0.hitStart + first_hit] = accept_track && (t.hitsNum >= MIN_HITS_TRACK);
        if(accept_track && (t.hitsNum >= MIN_HITS_TRACK)) {
          tracks[s0.hitStart + first_hit] = t;
        }
      }
    }
  }
}


/* Calculating the chi2 of a track is quite cumbersome.
It implies loading hit_Xs, hit_Ys, and sensor_Zs elements for each
hit of the track. This introduces branching, and is slow.

However, the track chi2 has to be calculated only when the
track has been created (the tx, ty values change).
*/

__device__ float trackChi2(Track& t) {
  float ch = 0.0;
  int nDoF  = -4 + 2 * t.hitsNum;
  Hit h;
  for (int i=0; i<MAX_TRACK_SIZE; i++) {
    // TODO: Maybe there's a better way to do this
    if(t.hits[i] != -1) {
      h.x = hit_Xs[ t.hits[i] ];
      h.y = hit_Ys[ t.hits[i] ];

      ch += hitChi2(t, h, hit_Zs[ t.hits[i] ]);
    }
  }
  return ch/nDoF;
}

__device__ float hitChi2(Track& t, Hit& h, int hit_z) {
  // chi2 of a hit
  float dx = (t.x0 + t.tx * hit_z) - h.x;
  float dy = (t.y0 + t.ty * hit_z) - h.y;
  return dx * dx * PARAM_W + dy * dy * PARAM_W;
}


/** The postProcess method takes care of discarding tracks
which are redundant. In other words, it will (hopefully) increase
the purity of our tracks.

- Inspect track_holders and generate track_indexes and num_tracks

The main idea is to accept tracks which have unique (> REQUIRED_UNIQUES) hits.
For this, each track is checked against all other more preferent tracks, and
non common hits are kept.

TODO: Change preference system by something more civilized.
A track t0 has preference over another t1 one if:
t0.hitsNum > t1.hitsNum ||
(t0.hitsNum == t1.hitsNum && chi2(t0) < chi2(t1))
*/
__global__ void postProcess(Track* tracks, bool* track_holders, int* track_indexes, int* num_tracks, int* tracks_to_process) {
  // tracks_to_process holds the list of tracks with track_holders[t] == true
  
  // TODO: Try with sh_tracks_to_process
  // __shared__ int sh_tracks_to_process[MAX_POST_TRACKS];

  __shared__ Track sh_tracks[BUNCH_POST_TRACKS];
  __shared__ float sh_chi2[BUNCH_POST_TRACKS];

  __shared__ Track sh_next_tracks[BUNCH_POST_TRACKS];
  __shared__ float sh_next_chi2[BUNCH_POST_TRACKS];
  
  // We will use an atomic to write on a vector concurrently on several values
  __shared__ int tracks_to_process_size;
  __shared__ int tracks_accepted_size;

  tracks_to_process_size = 0;
  tracks_accepted_size = 0;

  __syncthreads(); // for the atomics tracks_to_process_size, and tracks_processed

  int i, j, current_track, next_track;
  bool preferent;

  for(i=0; i<int(ceilf( ((float) no_hits[0]) / blockDim.x)); ++i) {
    current_track = blockDim.x * i + threadIdx.x;
    if(current_track < no_hits[0]) {
      // Iterate in all tracks (current_track)

      if(track_holders[current_track]) {
        // Atomic add
        int current_atomic = atomicAdd(&tracks_to_process_size, 1);

        // TODO: This condition shouldn't exist,
        // redo using method to process in batches if necessary
        // if(current_atomic < MAX_POST_TRACKS)
        tracks_to_process[current_atomic] = current_track;
      }
    }
  }

  __syncthreads();

  // Iterate in all current_tracks against all next_tracks.
  // Do this processing on batches of blockDim.x size
  for(i=0; i<int(ceilf( ((float) tracks_to_process_size) / blockDim.x)); ++i) {
    current_track = blockDim.x * i + threadIdx.x;
    if(current_track < tracks_to_process_size) {
      // Store all tracks in sh_tracks
      sh_tracks[threadIdx.x] = tracks[tracks_to_process[current_track]];

      // Calculate chi2
      sh_chi2[threadIdx.x] = trackChi2(sh_tracks[threadIdx.x]);
    }

    __syncthreads();

    // if(sh_tracks[threadIdx.x].hits[0] == 987)
    //   i = 20;

    // Iterate in all next_tracks
    for(j=0; j<int(ceilf( ((float) tracks_to_process_size) / blockDim.x)); ++j) {
      next_track = blockDim.x * j + threadIdx.x;

      if(next_track < tracks_to_process_size) {
        // Store all tracks in sh_tracks
        sh_next_tracks[threadIdx.x] = tracks[tracks_to_process[next_track]];

        // Calculate chi2
        sh_next_chi2[threadIdx.x] = trackChi2(sh_tracks[threadIdx.x]);
      }

      __syncthreads();

      // All is loaded, commencing assault!
      for(int k=0; k<BUNCH_POST_TRACKS; ++k) {
        next_track = blockDim.x * j + k;

        if(current_track < tracks_to_process_size && next_track < tracks_to_process_size) {
          /* Compare all tracks to check uniqueness, based on
          - length
          - chi2

          preferent is a boolean storing this logic. It reads,
        
          TODO: Change preference system by something more civilized
          next_track is preferent if
            it's not current_track,
            its length > current_track . length OR
            (its length == current_track . length AND
            chi2 < current_track . chi2)
          */
          preferent = current_track!=next_track &&
                    (sh_next_tracks[k].hitsNum > sh_tracks[threadIdx.x].hitsNum ||
                    (sh_next_tracks[k].hitsNum == sh_tracks[threadIdx.x].hitsNum &&
                    sh_next_chi2[k] < sh_chi2[threadIdx.x]));

          // Preference system based solely on chi2
          /*preferent = current_track!=next_track &&
                    sh_next_chi2[k] < sh_chi2[threadIdx.x]; */

          // TODO: Maybe there's a better way...
          if(preferent) {
            // Eliminate hits from current_track, based on next_track's
            for(int current_hit=0; current_hit<MAX_TRACK_SIZE; ++current_hit) {
              for(int next_hit=0; next_hit<MAX_TRACK_SIZE; ++next_hit) {
                /* apply mask:
                a[i] = 
                  (a[i] == b[j]) * -1 +
                  (a[i] != b[j]) * a[i]
                */
                sh_tracks[threadIdx.x].hits[current_hit] =
                  (sh_tracks[threadIdx.x].hits[current_hit] == sh_next_tracks[k].hits[next_hit]) * -1 + 
                  (sh_tracks[threadIdx.x].hits[current_hit] != sh_next_tracks[k].hits[next_hit]) *
                    sh_tracks[threadIdx.x].hits[current_hit];
              }
            }
          }
        }
      }
    }

    if(current_track < tracks_to_process_size) {
      // Check how many uniques do we have
      int unique = 0;
      for(int hit=0; hit<MAX_TRACK_SIZE; ++hit)
        unique += (sh_tracks[threadIdx.x].hits[hit]!=-1);

      if(!POST_PROCESSING || ((float) unique) / sh_tracks[threadIdx.x].hitsNum > REQUIRED_UNIQUES) {
        int current_track_accepted = atomicAdd(&tracks_accepted_size, 1);

        track_indexes[current_track_accepted] = tracks_to_process[current_track];
      }
    }
  }

  __syncthreads();

  if(threadIdx.x==0)
    num_tracks[0] = tracks_accepted_size;
}

