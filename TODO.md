## Data-Oriented Optimisation Backlog

1. **Stabilise process I/O buffers** *(watcher.odin:454-505)*  
   - Persist stdout/stderr byte slabs and OVERLAPPED structs inside `ProcessIOState` instead of reallocating them every poll tick.  
   - Reset lengths/events instead of allocating to keep CPU caches hot and eliminate allocator churn.  
   - Measure: expect fewer heap calls per second, steadier RSS, and lower latency in tight watch loops.

2. **Batch decode directory notifications** *(watcher.odin:556-600)*  
   - Treat the `ReadDirectoryChangesW` block as a struct-of-arrays batch (actions, offsets, lengths, hashes).  
   - UTF-8 convert and filter only the rows that survive extension checks to cut string work on ignored files.

3. **Preparse build templates** *(watcher.odin:603-677)*  
   - Parse `arg_info.build_template` once into literal spans + placeholder descriptors.  
   - Assemble commands via memcpy of literals plus direct insertion of dynamic spans (file/out/target), eliminating per-trigger splits and joins.

4. **Hash-based filename filters** *(watcher.odin:570-589)*  
   - Replace repeated `strings.has_suffix/contains` calls with a small hashed table or bitset of skip/build extensions.  
   - Express state as membership in these tables to keep the hot filtering path branch-light and cache-resident.
