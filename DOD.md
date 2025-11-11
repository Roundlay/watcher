# DATA-ORIENTED DESIGN PRINCIPLES

1. Organize by Data Dependencies, Not Conceptual Groupings

- **Don't:** Group all attributes of a conceptual entity into one struct because they're "related".
- **Do:** Group attributes that are accessed together, change together, or have the same lifetime.

EXAMPLE

Instead of `struct Entity { pos, vel, mesh, ai, health }`, consider separate arrays for `positions[]`, `velocities[]`, `renderData[]`, `aiData[]`.

2. Eliminate Optional Fields Through Separation

- **Problem**: `struct Pickup { mesh, texture, tint?, animation? }` wastes space with null/optional fields.
- **Solution**: Create separate collections:
    - `struct Pickup { id, mesh, texture, type }`
    - `struct TintedPickup { pickupId, tint }` (only exists for pickups that have tints)
    - `struct AnimatedPickup { pickupId, animation }` (only exists for pickups with animations)
- **Principle**: Presence in a collection implies the property exists; absence means it doesn't.

3. Prefer Arrays of Structs Over Individual Objects

- **Instead of:** Scattered heap allocations with pointers connecting things...
- **Use:** Contiguous arrays where entities are indexed by integer IDs.

EXAMPLE

```
// Not this:
Entity* entities[1000]; // pointers to scattered objects

// This:
struct Entity { ... };
Entity entities[1000];  // contiguous array
```

4. Use Indices/IDs as Handles, Not Pointers

- **Replace:** pointer members such as `Player* owner` or `Door* nextDoor`.
- **With:** fixed-width handles (`uint32_t ownerId`, `uint32_t nextDoorId`) that index arrays directly.
- **Benefits:** handles stay compact (4 B vs 8 B), serialize trivially, survive relocations, and let you jump straight to `entities[entityId]` without chasing pointers.

5. Store Relationships in Separate Collections

- **Don't:** bake relationships into each object; that explodes storage and forces per-object scans.
- **Do:** store relationships as flat link tables so each many-to-many mapping is its own data stream.

EXAMPLE

```c
// Instead of:
struct Room {
    Door doors[10];
    Pickup* pickups[20];
};

// Use link rows:
struct RoomDoorLink { uint32_t roomId; uint32_t doorId; };
struct PickupPlacement { uint32_t roomId; uint32_t pickupId; };
RoomDoorLink roomDoors[];
PickupPlacement pickupLocations[];
```

6. Separate Instance Data from Shared Type Data

- **Split:** archetype/type records (shared meshes, textures, constants) from per-instance state.
- **Reference:** archetypes by `typeId` so thousands of instances share one immutable blob.

EXAMPLE

```c
// Shared data (once per type)
struct WeaponArchetype {
    uint32_t typeId;
    MeshId mesh;
    TextureId texture;
    float baseDamage;
};
WeaponArchetype weaponTypes[NUM_WEAPON_TYPES];

// Instance data (per entity)
struct WeaponInstance {
    uint32_t instanceId;
    uint32_t typeId;
    float durability;
    uint32_t ownerId;
};
WeaponInstance weapons[];
```

7. Decompose by Access Patterns

- **Detect:** attributes that update on different cadences (per frame vs per event vs immutable).
- **Split:** each cadence into its own array so hot loops only touch hot data.

EXAMPLE

```c
// Instead of:
struct Enemy {
    Vector3 position;
    AIState aiState;
    MeshId mesh;
    Health health;
};

// Use per-attribute streams:
Vector3 enemyPositions[];
AIState enemyAI[];
MeshId enemyMeshes[];
Health enemyHealth[];
```

8. Use Parallel Arrays for Different Update Frequencies

- **Keep together:** attributes that update or stream together (transforms vs rendering).
- **Struct-of-arrays:** for each subsystem so cache lines stay fully utilized.

EXAMPLE

```c
struct TransformData {
    Vector3 positions[MAX_ENTITIES];
    Quaternion rotations[MAX_ENTITIES];
    Vector3 scales[MAX_ENTITIES];
};

struct RenderData {
    MeshId meshes[MAX_ENTITIES];
    MaterialId materials[MAX_ENTITIES];
    BoundingBox bounds[MAX_ENTITIES];
};
```

9. Compound Keys for Multi-Dimensional Lookups

- **When identity spans axes:** (type, quality, tier...), flatten them into deterministic keys.
- **Lookup:** either as nested arrays or a single linearized index derived from the compound key.

EXAMPLE

```c
struct WeaponStats {
    WeaponType type;
    QualityLevel quality;
    int damage;
};

int damage = weaponStats[type][quality].damage;
// or
int idx = type * NUM_QUALITIES + quality;
int damage = weaponStatsLinear[idx].damage;
```

10. Express State Through Collection Membership

- **Skip:** boolean flags for mutually exclusive states.
- **Use:** membership arrays where being present in `lockedDoorIds[]` means "locked" and absence means "unlocked."

EXAMPLE

```c
struct Door { uint32_t id; /* static properties */ };
uint32_t lockedDoorIds[];
uint32_t openDoorIds[];
```

11. Use Bitsets for Dense Boolean Properties

- **Problem:** three booleans per entity burn bytes and fragment cache lines.
- **Solution:** pack each boolean axis into a bitset and test with shifts and masks.

EXAMPLE

```c
struct EntityBits {
    uint64_t active[MAX_ENTITIES / 64];
    uint64_t visible[MAX_ENTITIES / 64];
    uint64_t dirty[MAX_ENTITIES / 64];
};

bool isActive = (bits.active[id / 64] & (1ULL << (id % 64))) != 0;
```

12. Design for Batch Operations

- **Process:** entities in wide loops so the compiler can unroll and vectorize.
- **Avoid:** per-entity virtual calls or pointer chasing in the hot update.

EXAMPLE

```c
// Scalar per-entity update (slow)
void updateEntity(Entity* e, float dt) {
    e->position += e->velocity * dt;
}

// Batch transform (SIMD friendly)
void updatePositions(Vector3* positions, Vector3* velocities,
                     int count, float dt) {
    for (int i = 0; i < count; i++) {
        positions[i] += velocities[i] * dt;
    }
}
```

13. Add Features by Adding Collections, Not Modifying Structs

- **Extend:** systems by adding new parallel arrays keyed by entity IDs.
- **Leave:** baseline structs untouched so cache-friendly layouts stay stable.

EXAMPLE

```c
struct Enemy { uint32_t id; Vector3 pos; Health health; };
struct RegenerationData { uint32_t enemyId; float regenRate; };
RegenerationData regeneratingEnemies[];
```

14. Compression Through Domain Knowledge

- **Exploit:** invariants (grid-aligned positions, limited velocity ranges, repeated prefixes).
- **Store:** the smallest representation that preserves required fidelity.

EXAMPLE

```c
// Grid-aligned positions
uint16_t gridX, gridY, gridZ;  // multiply by cell size when needed

// Small velocities
int16_t velX, velY, velZ;      // fixed-point scaling factor

// Structured IDs
enum EntityType { GOBLIN };
uint16_t instanceNumber;       // replaces long string names
```

15. Structure of Arrays (SoA) Over Array of Structures (AoS)

- **AoS pain:** interleaves unrelated attributes so cache lines drag unused bytes.
- **SoA win:** keeps each attribute contiguous for burst loads/stores.

EXAMPLE

```c
// Array of Structures
struct Particle {
    Vector3 position;
    Vector3 velocity;
    Color color;
    float lifetime;
};
Particle particles[1000];

// Structure of Arrays
struct ParticleSystem {
    Vector3 positions[1000];
    Vector3 velocities[1000];
    Color colors[1000];
    float lifetimes[1000];
};
```

16. Normalize Redundancy

- **Detect:** strings or blobs duplicated across instances.
- **Refactor:** shared attributes into archetype tables referenced by tiny IDs.

EXAMPLE

```c
struct EnemyArchetype {
    uint32_t typeId;
    char modelName[64];
    char textureName[64];
};

struct Enemy {
    uint32_t typeId;   // points at archetype
    Vector3 position;  // per-instance data
};
```

## Core Mental Model

- Think in columns: each array is one attribute; the implicit row index is the entity.
- Query only the columns a transform needs; everything else stays cold in cache.
- Express relationships with integers, not pointers, so data stays relocatable.
- Encode state as membership in collections; absence is as meaningful as presence.
- Organize strictly by access pattern and dependency graph, not by conceptual objects.
