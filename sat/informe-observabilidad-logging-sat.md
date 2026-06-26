# Evaluación de Logging y Observabilidad de Aplicaciones — SAT

**Proyecto:** Tigo Panamá — Zeus
**Alcance:** Clúster SAT (comenzando por **dev**), logs de aplicación primero; service mesh (Istio + Kiali) y Kibana como fases posteriores.
**Clúster de referencia:** GLX (UAT) — usado para ver qué ya está instalado y qué es reutilizable.
**Estado:** Evaluación / propuesta. **No se ha aplicado nada en ningún clúster.**
**Fecha:** 2026-06-23

Relacionado: [[sat-dev-analysis]] · [[sat-uat-analysis]] · [[sat-dev-observability-plan]] · [[sat-observability-logging-report]]

---

## 1. Resumen ejecutivo

- Ni SAT ni GLX tienen service mesh. Mesh en SAT es greenfield.
- SAT y GLX están totalmente aislados; SAT necesita su propio backend de logs.
- Todos los logs son texto plano — cero JSON.
- Hallazgo central: el logging está centralizado en las imágenes base compartidas. La base Spring ya implementa `CorrelationIdFilter`. Se puede estandarizar en la capa de imagen base SIN tocar código de aplicación.
- Restricción: sin cambios de código → dos vías libres de código: L1 (pipeline) y L2 (imagen base).
- Decidido: Elastic + Kibana propios vía ECK; logs primero, mesh en paralelo.

(ver markdown completo en el HTML/PDF)
