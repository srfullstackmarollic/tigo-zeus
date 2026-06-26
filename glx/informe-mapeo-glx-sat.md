# Informe de Mapeo de Plataforma y Aplicaciones — Galaxion (GLX) + SAT

**Clusters:** GLX `tocpait-glx-sit` (SIT) · `tocpait-glx-uat` (UAT) · `tocpait-glx` (Master/PROD) · SAT `tocpait-sat-dev` (dev) — Tigo Panamá
**Recolectado:** 2026-06-23 (GLX) / 2026-06-22 (SAT dev) — solo lectura, vía nodos master bastión, kubeconfig RKE2
**Alcance:** GLX — aplicaciones bajo nuestra responsabilidad (subconjunto del namespace `glx`) + componentes de plataforma; SAT dev — **solo a nivel de plataforma**.
**Estado:** GLX SIT · UAT · Master — completo. SAT dev — nivel de plataforma (de relevamiento previo).

Documentos relacionados: [[sat-dev-analysis]] · [[sat-observability-logging-report]] · [[sat-dev-observability-plan]] · [[informe-observabilidad-logging-sat]]

## 0. Hallazgos principales
1. Plataformas asimétricas entre los cuatro clusters.
2. 🔴 Incidente de pull de imágenes en PROD (~4 días).
3. Topología de registry distinta por entorno; `maildev` desde Docker Hub público.
4. Sin resiliencia en ningún entorno (1 réplica + sin HPA).

(Contenido completo en el PDF.)
