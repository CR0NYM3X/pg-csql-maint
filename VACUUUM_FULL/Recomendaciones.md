
### **Recomendación de p_profile y p_scope:**

1. **`p_profile = 'SMART'` (Por defecto):** Utiliza la evaluación JIT y los `$X$` días de persistencia.
2. **`p_profile = 'FORCE_SURGERY'` (El nuevo Aggressive):** Saltará las reglas matemáticas y hará el `VACUUM FULL` a ciegas, **PERO** el código exigirá que obligatoriamente `p_scope = 'CUSTOM_LIST'`. Si intentas forzar a ciegas un `ALL_USER`, el procedimiento lanzará una excepción y abortará para proteger el servidor.
