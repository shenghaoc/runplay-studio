# Training-load kernel requirements

- Translate TrainingLoad.cpp literally, including validation order, the five inclusive zone thresholds, reserve clamping, and weighted accumulation.
- Keep the training-load service, public models, cancellation, policy, and persistence behavior unchanged.
- Use one borrowed-span Swift engine call per measured pass; typed errors never return partial values.
- Retain the C++ source throughout migration and compare all summary bits before retiring it.
