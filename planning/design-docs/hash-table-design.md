# Hash Table Design

A hash table stores associations between keys and values.  Given a key, we
want to find its value without searching every entry.  A hash function turns
the key into an integer.  The table uses that integer to select a position
where the search begins.

Different keys can select the same position. This is a collision, and a
hash table needs a way to handle it.  Hash tables are generally divided into
two families according to how they resolve collisions: **open addressing**
and **separate chaining**.

With **Open Addressing**, a collision leads to another position in the
table.  Insertion follows a probing rule until it finds an available slot.
Lookup follows the same rule, checking candidate keys until it finds a
match or establishes that the key is absent.

With **Separate Chaining**, each table position is a bucket that identifies
a collection of entries.  Keys that select the same bucket go into that
collection.  A common implementation uses a linked list: the bucket holds
a pointer to the first entry, and each entry holds a pointer to the next.
Lookup first selects the bucket and then from there walks the list if any, 
checking keys for a match. Perl has historically used this pointer-based form 
of separate chaining.

In addition Perl has a special optimization in place where keys are shared
amongst the hash tables in memory.  A special hash table actually owns the
keys, and uses a refcount to manage the lifetime of the key.  As long as one
copy of the key is in a hash somewhere using the key elsewhere is free. This
does mean that store operations in perl can be a little bit slower than they
are in other languages, at the cost of a greatly reduced memory footprint
from reused keys. 

Python's dictionary provides a useful comparison. It uses open-addressing,
but its hash index contains integers into an array of key/value entries
which is maintained in insertion order. It does not share keys amongst
different hashes typically.

## Comparing Open Addressing and Separate Chaining

Open addressing typically has less pointer indirection, but has the
disadvantage that the load-factor (the ratio of used to total buckets) of the
table can not go above 1 without being resized. It also has the problem that
different hash buckets blead into each other, forming clusters in the table,
and making collisions more likely, as if there is a collision it is just as
likely to be with a neighboring bucket as it with its own bucket. This usually
means that OA prefers to maintain a relatively low load factor (ratio of
buckets used to total buckets).

Separate chaining typically is more expensive per item in a bucket, with
more indirection required to find the next item in the bucket, etc. However
it tends to have to look at less items because it only has to deal
with collisions in its exact bucket, and not the buckets of its neighbors.
Separate chaining also has the advantage that the load-factor can grow
above 1 without having to resize the index, although it should usually
be much lower than that. 

## Pointer Tables versus Offset Tables

Both Open Addressing and Separate Chaining can be implemented with pointer 
based hash tables or with offset based hash tables.

Pointer based tables are fairly straightforward.  With OA each bucket points at
a key/value record.  With SC each bucket points at an element of a linked list
which in turn points at the key/value data. A key issue with this design is that
pointers are relatively large.  Each pointer slot might take 8 bytes.  If most
of the buckets are empty this means a lot of wasted space.  In the SC model it
means a node in the linked list can be quite large, for instance 3 pointers. 

Offset based tables are a little more complex. In this structure there are two
arrays.  The first is used for the hash function lookups, and contains offsets
into the data in the second array which contains the actual key/value data.
This has the immediate advantage that the indexes can be smaller than a pointer,
like half or less, which can be a big saving for larger tables. A second advantage
is that it is much more efficient to traverse over all the key/value pairs,
and with only a little bit of extra effort the structure will preserve insertion
order at the same time which can be very convenient in a number of different ways.
In SC the offset table is completed by a next table, which contains the index
of the next item in the same bucket.

## The traditional Perl hash table

Perl has historically used a bucket array containing pointers to linked hash
entries, called `HE`s. Each entry holds a pointer to the next entry in its
bucket, a pointer to a key record (`HEK`), and a pointer to the scalar value
(`SV`). 


```text
 Bucket array          HE: 24 bytes
 +-----------+         +------------------+
 | NULL      |         | next pointer: 8 B|----> next HE / NULL
 +-----------+         +------------------+
 | HE pointer|-------->| value pointer:8 B|----> SV
 +-----------+         +------------------+
 | NULL      |         | key pointer:  8 B|----+
 +-----------+         +------------------+    |
      ...                                      |
 Each slot: 8 bytes                            v
                                HEK: 10 bytes + key length
                                +-------------------------+
                                | Cached hash:        4 B |
                                | Key length:         4 B |
                                | Key bytes:     variable |
                                | NUL terminator:     1 B |
                                | Flags:              1 B |
                                +-------------------------+
```

The sizes shown assume a typical 64-bit build with eight-byte pointers. The
field order is simplified for illustration. Every bucket slot occupies eight
bytes, including empty slots. Each `HE` occupies 24 bytes, excluding its key
and value storage.

The `HEK` stores the cached hash, the key length in bytes, the key bytes, a
NUL terminator, and a flags byte. Its fields occupy **10 bytes plus the key
length**. For example, the five-byte key `apple` requires 15 bytes for
these fields. Allocation rounding and additional shared-key metadata are
separate costs.

## Shared keys and `PL_strtab`

Ordinary Perl hashes can share key records. When several hashes contain the
same key, their entries can point to the same `HEK`, while each entry retains
its own value pointer. Sharing avoids storing another copy of the key bytes
and cached hash for each hash.

`PL_strtab` is the interpreter’s shared string table. In the traditional
representation, it uses the hash-entry machinery to track shared keys, with a
reference count occupying the entry’s nominal value field. An ordinary hash
entry’s value points to an `SV`; the corresponding string-table entry
instead records references to the shared key.

The traditional shared-key allocation contains both the string table’s `HE`
and the `HEK`. The diagram above shows the ordinary hash entry pointing to the
key record; it does not show that additional string-table entry.

For example, two hashes containing the key `name` have separate ordinary
`HE`s and separate values, but can share one key record:

```text
 Hash A                      Shared key                      Hash B
 +----------------+          +----------------+          +----------------+
 | key pointer    |--------->| HEK for "name" |<---------| key pointer    |
 | value pointer  |          +----------------+          | value pointer  |
 +----------------+                  ^                   +----------------+
         |                           |                           |
         v                    PL_strtab entry                    v
      SV "Alice"              holds refcount                  SV "Bob"
```

Sharing works across hashes with different sets of keys. The shared object
is the individual key record. Its reference count tracks its users, and
releasing the last reference removes it from the string table and frees it.

## Python separates the index from the entries

CPython's ordinary combined dictionary uses an open-addressed table of
integer indexes into an entry array. A lookup probes the index table and
uses each candidate index to examine an entry. Small tables use narrow
indexes, with wider indexes used as the table grows.

```text
 Open-addressed index           Entry array
 +------------------+           +-------------------------+
 | empty            |           | 0: first inserted entry |
 | 2                |           | 1: next inserted entry  |
 | 0                |           | 2: another entry        |
 | empty            |           +-------------------------+
 | 1                |             Traverse in entry order
 +------------------+
   Probe in hash order
```

The index value identifies an entry position; the diagram separates the
two arrays schematically. New keys append to entry storage. Iteration walks
that storage, skipping deleted entries, so hash placement does not determine
iteration order. Updating an existing key retains its position. This
separation supports compact indexing and insertion-order traversal.
[CPython dictionary implementation](https://github.com/python/cpython/blob/3.14/Objects/dictobject.c)

Python also supports shared key tables for instance attribute dictionaries.
That shares a table of keys among related dictionaries, rather than using
Perl's interpreter-wide table to share individual key records.
[PEP 412](https://peps.python.org/pep-0412/)

## A New Hybrid Approach: Different Strategies for `Pl_strtab` and other hashes

Traditionally `PL_strtab` was implemented more or less the same as a normal hash
with the only difference being that its values were refcounts and not pointers.
In this new hybrid model `PL_strtab` is implemented differently from the rest,
with an Open Addressing pointer based hash table.

Other hash tables are implemented with dynamically scaled offset based Separate 
Chaining with insert order preservation support, and some optimisations for
very small hashes.

### Ordinary hashes use compact entries and scaled offsets

Each ordinary `HE` retains its key and value pointers, but loses its next
pointer. On a typical 64-bit build, this reduces the record from 24 to 16
bytes. Entries live in an array, and the lookup index identifies their
positions.

The chain index consists of bucket heads and a separate next-link array.
Both contain entry positions encoded as position plus one. Zero means an
empty bucket or the end of a chain. These are entry offsets, not byte
offsets or machine pointers.

```text
 Bucket heads             Next links               HE array
 +-----------+            +-----------+            +------------------+
 | 0         |            | entry 0: 3|            | 0: key + value   |
 | 1         |---+        | entry 1: 0|            | 1: key + value   |
 | 2         |   |        | entry 2: 0|            | 2: key + value   |
 +-----------+   |        +-----------+            +------------------+
                 |
                 +--> entry 0 --> entry 2 --> end
                      encoded 1   encoded 3   encoded 0
```

The space allocated for offsets widens as the capacity of the hash grows: 
one byte through 256 slots, two bytes through 65,535 slots, and four bytes 
above that. A small hash therefore pays one byte for a bucket head and one 
byte for a chain link, rather than eight-byte pointers for each. Bucket 
capacity and entry capacity can grow independently.

New entries append to entry storage.  Deletion leaves holes, and compaction
packs the surviving entries without reversing their relative order.  This
supports order preservation while allowing the chains to be rebuilt
independently.  Iteration follows the entry array rather than the buckets.
Updating a value need not move its entry but deleting and reinserting a key
places a new entry at the end. 

### Very Small Keycount Support

Searching a short array in C is very efficient, and can be on par or even
faster than using a hash table as the index. As such very small hashes are
not actually hashes at all but either a single pointer to an arena allocated
HE, or to a short array of HE elements (2-8 keys). 

### The shared string table uses open addressing over key pointers

The string table stores `HEK *` pointers in an open-addressed slot array.
The key records remain separately allocated, so rebuilding the slot array
does not move keys referenced by ordinary hashes. Each shared-key allocation
holds the reference count alongside its `HEK`, without a full string-table
`HE`.

When the last reference to a shared key is released, deletion uses its
cached hash to probe for the slot holding that exact `HEK *`. It replaces
the pointer with a tombstone, preserving the probe paths needed to find
other keys. There is no stored deletion backlink. A backlink would avoid
this probe, but would require per-key metadata and maintenance when slots
move during a rebuild.

This gives the two tables different lookup structures while retaining
shared key records: open addressing for the key table, and compact
offset-based separate chaining for ordinary hashes. The entry array
separates iteration order from collision handling, as it does in Python.

### Implementation scope

The existing implementation notes describe append-ordered entry storage
but do not promise public insertion-order semantics. The scope of the
ordering guarantee needs to be established separately from the storage
mechanism.

### An indexed shared string table could save more memory

An alternative is to replace the shared string table's pointer buckets
with 32-bit indexes into a separate array of `HEK *` pointers. This does
not require the key allocations themselves to share a base address.
The bucket table and pointer array can have independent capacities.

On a 64-bit build, let `B` be bucket capacity and `P` be pointer-array
capacity. Excluding allocation headers and unchanged key storage:

```text
Pointer buckets:             8 * B bytes
32-bit indexes + pointers:   4 * B + 8 * P bytes
```

The indexed form saves memory when `P < B / 2`. With a proposed maximum
load factor of 0.5, doubling the bucket table produces occupancy around
25 percent, rising toward 50 percent before the next growth. If pointer
capacity closely tracks live keys, the indexed form ranges from about
25 percent less table storage after doubling to break-even at 50 percent
occupancy. Pointer-array slack reduces the saving. The index range must
also leave room for empty and deleted-slot encodings.

This is a proposed alternative, not the current string-table layout or
growth policy. It adds an indirection to lookup and requires a policy for
holes and compaction in the pointer array. Those costs need to be measured
against the memory saving.

## Memory and performance

The intended result is lower memory use with broadly comparable lookup
performance, and faster traversal where contiguous entry storage helps.
Removing the next pointer reduces the entry record. Narrow identifiers
reduce index storage. Direct entry traversal avoids scanning empty buckets
and walking pointer-linked entries.

The complete memory comparison must include bucket and entry capacities,
chain links, shared-key metadata, allocation rounding, and arena
overhead. Lookup, construction, iteration, deletion, and repeated mutation
should be measured separately. This lets us explain which representation
changes save memory and which operations benefit from them.
