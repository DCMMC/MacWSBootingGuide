# MacWSHost test support

This directory contains explicit regression/profile entry points. Test code
must run only after a `macwshost://performance-*` action or a Control Center
test action. Production streaming, input routing and presentation must not
depend on test fixtures or diagnostic flags.

Production telemetry is implemented by `MacWSPerformanceMonitor`. Synthetic
gesture scheduling is implemented by `MacWSPerformanceGestureScenario`; the
view supplies small emit callbacks so every scenario still crosses the exact
production input boundary. New synthetic scenarios belong here rather than in
transport, renderer or application-launch modules.
