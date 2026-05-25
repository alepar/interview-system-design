---
slug: autonomous-driving-inference
archetype: ml-in-loop
sources:
  ijsat_av_latency: ijsat.org/papers/2025/1/2462.pdf
  tesla_hydranet_blog: saneryee-studio.medium.com/deep-understanding-tesla-fsd-part-1-hydranet-1b46106d57
  tesla_occupancy_blog: thinkautonomous.ai/blog/occupancy-networks/
  waymo_6th_gen: automotivedive.com/news/waymo-6th-generation-driver-autonomous-driving-hardware-robotaxi-lidar-ai/725519/
  waymo_multipath_paper: arxiv.org/pdf/1910.05449
  asil_d_patsnap: patsnap.com/resources/blog/rd-blog/fail-operational-architecture-for-l4-avs-patsnap-eureka/
  waymo_safe_ai_2025: Waymo blog "Demonstrably Safe AI for Autonomous Driving" Dec 2025
---

# Autonomous-driving perception+planning inference — <100ms physics-bounded + HydraNet/Occupancy Network + Waymo sensor fusion + ASIL-D fail-operational

## Bar anchors
- **Mid-level (L4/E4):** "Object detection + planning." No latency budget; no safety architecture; no sensor fusion specifics.
- **Senior (L5/E5):** Names camera + lidar + radar + planning. Discusses real-time perception. May or may not articulate physics-bounded latency, ASIL-D fail-operational, HydraNet multi-task amortization, or fleet-driven data-engine moat.
- **Staff+ (L6/E6+):** Drives proactively. Articulates **safety-critical embedded inference** — architecturally distinct from cloud-served ranking. Cites **<100ms end-to-end** perception → planning → control (3.3m unactuated travel at highway 120 km/h per 100ms; physics-bounded). Names **Tesla HydraNet**: shared ResNet backbone + multi-scale transformer fusion + spatial RNN video module + ~50 task-specific heads (objects, lanes, signs, depth, occupancy); chosen to amortize compute across many tasks. Names **Tesla Occupancy Network** (AI Day 2022): 3D occupancy + flow from 8 cameras (12-bit raw) at ~10ms on AOP/FSD chip; replaces 2D-BEV abstraction; feeds downstream planning's vector-space world model. Names **Waymo 6th-gen Driver**: 13 cameras + 4 lidars + 6 radars + audio mics; fuses all modalities (no single-sensor priority — when sensors disagree, AI merges all available data); HD-map matching for cm-scale localization. Cites Waymo's **MultiPath/VectorNet/TNT/ChauffeurNet** two-stage prediction net: shared scene encoder + per-agent attention head producing multi-modal probabilistic trajectories with anchors. Cites **Waymo One ~100K paid driverless rides per week** (2024+) across Phoenix, SF, LA. Names **fail-operational L4 architecture** via **ASIL-D decomposition** into two ASIL-B channels with design diversity + redundant compute/network/power. Names **Tesla data-engine moat**: lightweight on-vehicle trigger classifiers flag rare/edge events; raw clips uplinked → labeled → retrained → OTA-redeployed. The architectural moat is the labeled-data flywheel, not the network architecture. Stretch (Sr Staff bar): cites **Waymo System 1 / System 2 architecture** (fast Sensor Fusion Encoder + slow Driving VLM with Critic model providing RL verifiable feedback) per Waymo *Demonstrably Safe AI* Dec 2025.

## Canonical decomposition

### Requirements
**Functional:**
- Perception: object detection (cars, pedestrians, traffic lights), lane detection, sign reading, depth, 3D occupancy
- Planning: behavior prediction + trajectory optimization respecting traffic rules + safety
- Control: actuation (steering, throttle, brake) within physics envelope
- Fleet data engine: trigger-classifier-driven clip upload → labeling → retraining → OTA deploy
- ASIL-D safety: fail-operational under component failure

**Non-functional (with numbers):**
- End-to-end perception → planning → control <100ms (3.3m unactuated travel at 120 km/h)
- Tesla Occupancy Network ~10ms on AOP/FSD chip
- Tesla HW3: ~36-72 TOPS dual-SoC; HW4: ~50-280 TOPS, 16GB RAM / 256GB storage; both dual-SoC cross-checking
- Waymo: 13 cameras + 4 lidars + 6 radars; 360° awareness up to 500m; ~100K paid driverless rides per week (2024+)
- NVIDIA DRIVE AGX Thor: 2,000 TFLOPS + ASIL-D safety redundancy
- Perception loop: multi-Hz (~10-20 Hz typically)
- Waymo cumulative: ~96M autonomous miles + 200M real + 20B simulated

### Core entities
- **Sensor frame:** synchronized (cameras + lidars + radars + IMU + audio) at multi-Hz cadence
- **Perception state:** detected objects (class + 3D pose + velocity) + lane geometry + occupancy grid + sign text
- **Prediction trajectories:** per-agent multi-modal probabilistic trajectories with anchors (MultiPath/VectorNet/TNT)
- **Plan:** ego-vehicle trajectory (5-10s horizon) optimizing safety + comfort + progress
- **Control commands:** steering, throttle, brake actuator commands
- **Trigger event:** rare edge case flagged by on-vehicle classifier → raw clip uploaded for labeling

### API
- Internal (on-vehicle): perception.detect(sensor_frame) → perception_state; predict(perception_state, hd_map) → trajectories; plan(trajectories, ego_state) → plan; control.actuate(plan) → commands
- Fleet: trigger_classifier.evaluate(clip) → bool upload; data_engine.label_and_retrain(clips); ota.deploy_model(model_artifact) with shadow + canary

### HLD
**On-vehicle inference stack**: synchronized sensor frames (cameras + lidars + radars + IMU; ~10-20 Hz cadence) → **perception** (HydraNet shared backbone + ~50 task-specific heads + Occupancy Network for 3D occupancy/flow) → **prediction** (per-agent multi-modal trajectories with anchors via MultiPath/VectorNet/TNT/ChauffeurNet two-stage net: scene encoder + per-agent attention head) → **planner** (trajectory optimization with prediction distributions as constraints) → **control** (actuator commands). **Hard latency budget**: <100ms end-to-end (3.3m unactuated travel at 120 km/h). **Dual-SoC architecture** (Tesla HW3/HW4 cross-check outputs; Waymo similar redundancy) for fail-operational L4. **HD maps** (Waymo): pre-built cm-scale; vehicle localizes against maps + real-time sensors. **Sensor fusion philosophy** (Waymo): no single-sensor priority; when sensors disagree, AI merges all available data. **Tesla data engine** (fleet loop): on-vehicle trigger classifiers flag rare events (cyclist at night, pedestrian in rain) → raw clips uplinked → human-labeled → model retrained → OTA-deployed with shadow validation + gradual fleet rollout + auto-rollback on disengagement-rate spike. **Waymo System 1 / System 2 (Dec 2025)**: fast Sensor Fusion Encoder produces object/embedding outputs at high frequency + slow Driving VLM does semantic reasoning + Critic model provides RL verifiable feedback signals for evaluation.

### Deep dives
1. **HydraNet + Occupancy Network (Tesla).** **HydraNet**: shared computation body + ~50 task-specific heads. Body: 8-camera ResNet backbone → multi-scale features → transformer fusion → feature queue (temporal) → spatial RNN video module. Heads: object detection, lanes, signs, depth, occupancy. Why one network: amortize compute across many tasks; share representations; reduce inference latency by avoiding multiple network passes. **Occupancy Network** (AI Day 2022): extends 2D BEV by adding height — predicts 3D occupancy + flow in vector-space world model. ~10ms on AOP/FSD chip. Feeds downstream planning's world model representation. Trade vs separate task-specific networks: monolithic HydraNet harder to iterate per task; partial separate training works (freeze backbone, fine-tune head).

2. **Waymo sensor fusion + behavior prediction.** **Sensors**: 13 cameras + 4 lidars + 6 radars + external mics. **Fusion philosophy**: no single-sensor priority — when sensors disagree, AI system merges all available data. **HD maps**: pre-built cm-scale; vehicle localizes against maps + real-time sensors. **Behavior prediction stack** (MultiPath/VectorNet/TNT/ChauffeurNet): two-stage net — shared scene encoder (whole-scene feature representation) → per-agent attention head producing multi-modal probabilistic trajectories with anchors. Downstream planner takes these distributions as constraints on trajectory optimization. **Closed-loop simulation** at extreme scale: 20B+ simulated miles + 200M real; SimulationCity pattern uses real-world incidents as scenario seeds.

3. **Fail-operational L4 + ASIL-D decomposition + Tesla data engine.** **L4 obligation**: vehicle must achieve safe state on component failure (not just shut down). **ASIL-D**: highest safety integrity. Often decomposed: two independent channels each rated ASIL-B with design diversity; combined satisfies ASIL-D. **Redundancy at three layers**: compute (dual SoC cross-check), network (dual CAN-bus or Ethernet), power (dual supplies). NVIDIA DRIVE AGX Thor as reference: 2,000 TFLOPS + ASIL-D on single SoC with lockstep safety cores. **Tesla data engine**: lightweight on-vehicle trigger classifiers (small ML models with criteria like "rare lane configuration" or "unusual pedestrian behavior") flag rare events; raw clips uplinked → labeled (human or auto-labeling pipeline) → retrained → OTA deployed. The architectural moat is **the labeled-data flywheel**, not the network architecture; millions of cars collect real-world data 24/7.

## Known failure modes
1. **Single-sensor failure mode.** Camera occluded by mud, lidar in snow, radar in metal-rich tunnel. Production answer: sensor fusion with graceful degradation; declared sensor health states; fall back to remaining-sensor inference; if too many fail, request safe-stop maneuver.

2. **Adversarial physical attacks.** Adversarial patches on signs (academic literature: subtle perturbations cause stop signs misread as speed limits), projected lights, road-graffiti. Production answer: robustness training; multi-modal sensor consistency check (lidar disagrees with camera classifier → flag); HD-map sanity check (sign location matches expected); per-decision confidence-based escalation.

3. **OTA update introduces regression.** Newly-deployed model performs worse on edge cases (e.g., unprotected left turn in dense urban). Production answer: shadow-mode validation on fleet data before rollout; gradual rollout (1% of fleet first); auto-rollback on disengagement-rate spike; per-region rollout (start in non-critical geography).

4. **Sim-to-real gap.** Simulation overstates a metric (e.g., perception accuracy in fog) that real fleet doesn't see. Production answer: sim-real divergence monitoring; explicit canary in real fleet before full deploy; weight sim metrics by sim-real divergence factor.

5. **Latency tail spikes** on GPU thermal throttling. Production answer: thermal management (cooling design + clock throttling); fallback model (smaller, faster) on thermal warning; explicit safe-stop on sustained thermal degradation.

## Notes for the coach
- **Asked-confirmed at Tesla, Waymo, Cruise, Aurora.** Karpathy Tesla AI Day talks, Waymo Engineering blog (including *Demonstrably Safe AI for Autonomous Driving* Dec 2025), NVIDIA DRIVE docs, academic AV safety literature — all explicit interview-prep canon.
- **The <100ms physics-bounded latency budget is the canonical Staff+ unlock.** Candidates who derive 3.3m unactuated travel at 120 km/h per 100ms demonstrate the physics-bounded framing.
- **The ASIL-D decomposition into ASIL-B channels is the safety-engineering depth probe.** Mid-senior candidates default to "we have redundancy"; Staff+ candidates name the ISO 26262 decomposition rule explicitly.
- **The Tesla data engine flywheel vs Waymo sensor-fusion redundancy is the strategic depth probe.** Tesla bets on vision generalization via fleet data; Waymo bets on sensor redundancy + HD maps. Articulating the trade-off demonstrates AV-industry literacy.
- **Adversarial probe: "Tesla doesn't use lidar — is Waymo's lidar-heavy approach obsolete?"** Strong answer: depends on operating domain (Tesla bets on vision generalization at fleet scale; Waymo bets on safety-critical sensor redundancy + HD maps for L4 robotaxi); ASIL-D obligations may favor lidar; Tesla is L2 augmented (driver-assist), Waymo is L4 (no driver) — different safety obligations. Weak answer: "Tesla is more advanced" without acknowledging the safety-level distinction.
