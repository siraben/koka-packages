/* A persistent hash map.

   ## Representation

   A weight-balanced binary search tree ordered by the *hash* of the key, with
   a bucket at each node holding every entry whose key hashes to that value.
   This gives O(log n) operations without needing bitwise arithmetic on Koka's
   arbitrary-precision `:int`, and it is persistent: an update shares all the
   structure it did not touch.

   A node stores two counts: how many entries are beneath it, which is what
   `size` reports in O(1), and how many nodes are beneath it, which is the
   weight the balancer uses.  They coincide only while no two keys collide, and
   only the node count is something a rotation can change -- see `hmap` below.

   ## Hash requirements

   A key type supplies `?hash : k -> int` and `?(==) : (k,k) -> bool`.  The
   only requirement is the usual one:

   > if `a == b` then `hash(a) == hash(b)`

   A hash need not be non-negative and need not be well distributed for the
   map to be *correct*; poor distribution only degrades a lookup within one
   bucket to a linear scan of that bucket.

   ## Iteration order

   Ascending hash value; within one bucket, least recently inserted first.
   This is deterministic for a given sequence of operations and for a given
   `hash`, but it is **not** insertion order and **not** key order, and it
   changes if the `hash` function changes.  Do not rely on it for output that
   users see: sort explicitly instead.

   ## Complexity

   | operation                    | cost                    |
   | ---------------------------- | ----------------------- |
   | `lookup`, `insert`, `remove` | O(log n) + O(bucket)    |
   | `size`                       | O(1)                    |
   | `list`, `keys`, `values`     | O(n)                    |
   | `(==)`                       | O(n log n)              |

   ## Sharing and reuse

   The tree is immutable, so a map may be shared freely.  `insert` rebuilds
   only the path from the root to the changed node -- O(log n) nodes -- and
   shares the rest.

   It does **not** currently reuse those nodes in place, even for a uniquely
   referenced map.  Koka's reuse analysis is intra-procedural: `insert-go`
   matches the `Bin` and acquires a reuse token, but the node is rebuilt
   inside `balance`, and the token is dropped at the call boundary -- visible
   as `kk_reuse_drop` in the generated `hashmap_map.c`.  Every insert
   therefore allocates a fresh path of O(log n) nodes.  Inlining the rebuild
   into `insert-go` would let the token through; until that is done and
   re-checked against the generated C, this is a known cost and not a
   guarantee.
*/
module hashmap/map

// A map from `k` to `v`.
pub type hmap<k,v>
  Tip
  // Two counts, because the two questions have different answers as soon as a
  // bucket holds more than one entry:
  //
  // * `size` counts *entries* in this subtree, which is what `size` reports,
  //   in O(1).
  // * `nodes` counts `Bin`s -- equivalently, distinct hash values -- and is
  //   the weight the balancer works with.
  //
  // Only `nodes` may be used for balancing.  A rotation moves nodes, and an
  // entry can only leave a bucket by being removed, so a balance invariant
  // stated on `size` is one no rotation can restore: three entries sharing a
  // hash, under a node with no sibling, would violate it permanently.
  Bin( size : int, nodes : int, hash : int, bucket : list<(k,v)>,
       left : hmap<k,v>, right : hmap<k,v> )

pub fun empty() : hmap<k,v>
  Tip

pub fun is-empty( m : hmap<k,v> ) : bool
  match m
    Tip -> True
    _   -> False

pub fun size( m : hmap<k,v> ) : int
  match m
    Tip                     -> 0
    Bin(n, _, _, _, _, _)   -> n

// ----------------------------------------------------------------------------
// balancing
//
// The standard weight-balanced scheme: a subtree may be at most `delta` times
// heavier than its sibling, and a `ratio` decides between a single and a
// double rotation.  The weight is the node count, never the entry count.
// ----------------------------------------------------------------------------

val delta : int = 3
val ratio : int = 2

// The balancer's weight: how many nodes a subtree has.
fun weight( m : hmap<k,v> ) : int
  match m
    Tip                     -> 0
    Bin(_, w, _, _, _, _)   -> w

fun bin( h : int, b : list<(k,v)>, l : hmap<k,v>, r : hmap<k,v> ) : hmap<k,v>
  Bin(b.length + l.size + r.size, 1 + l.weight + r.weight, h, b, l, r)

// Rebuild a node after one side gained or lost at most one node.
fun balance( h : int, b : list<(k,v)>, l : hmap<k,v>, r : hmap<k,v> ) : hmap<k,v>
  val ls = l.weight
  val rs = r.weight
  if ls + rs <= 1 then bin(h, b, l, r)
  elif rs > delta * ls then rotate-left(h, b, l, r)
  elif ls > delta * rs then rotate-right(h, b, l, r)
  else bin(h, b, l, r)

fun rotate-left( h : int, b : list<(k,v)>, l : hmap<k,v>, r : hmap<k,v> ) : hmap<k,v>
  match r
    Bin(_, _, rh, rb, rl, rr) ->
      if rl.weight < ratio * rr.weight
        then bin(rh, rb, bin(h, b, l, rl), rr)                     // single
        else match rl                                              // double
               Bin(_, _, rlh, rlb, rll, rlr) ->
                 bin(rlh, rlb, bin(h, b, l, rll), bin(rh, rb, rlr, rr))
               Tip -> bin(h, b, l, r)
    Tip -> bin(h, b, l, r)

fun rotate-right( h : int, b : list<(k,v)>, l : hmap<k,v>, r : hmap<k,v> ) : hmap<k,v>
  match l
    Bin(_, _, lh, lb, ll, lr) ->
      if lr.weight < ratio * ll.weight
        then bin(lh, lb, ll, bin(h, b, lr, r))                     // single
        else match lr                                              // double
               Bin(_, _, lrh, lrb, lrl, lrr) ->
                 bin(lrh, lrb, bin(lh, lb, ll, lrl), bin(h, b, lrr, r))
               Tip -> bin(h, b, l, r)
    Tip -> bin(h, b, l, r)

// ----------------------------------------------------------------------------
// lookup
// ----------------------------------------------------------------------------

pub fun lookup( m : hmap<k,v>, key : k, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div maybe<v>
  lookup-go(m, key.hash, key)

fun lookup-go( t : hmap<k,v>, hv : int, key : k, ?(==) : (k,k) -> bool ) : div maybe<v>
  match t
    Tip -> Nothing
    Bin(_, _, nh, b, l, r) ->
      if hv < nh then lookup-go(l, hv, key)
      elif hv > nh then lookup-go(r, hv, key)
      else bucket-lookup(b, key)

fun bucket-lookup( b : list<(k,v)>, key : k, ?(==) : (k,k) -> bool ) : div maybe<v>
  match b
    Nil -> Nothing
    Cons((k0, v0), rest) -> if k0 == key then Just(v0) else bucket-lookup(rest, key)

pub fun contains( m : hmap<k,v>, key : k, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div bool
  m.lookup(key).is-just

// The value for `key`, or `default` when absent.
pub fun get( m : hmap<k,v>, key : k, default : v, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div v
  match m.lookup(key)
    Just(x) -> x
    Nothing -> default

// ----------------------------------------------------------------------------
// insertion and update
// ----------------------------------------------------------------------------

// Insert, replacing any existing entry for `key`.
pub fun insert( m : hmap<k,v>, key : k, value : v,
                ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hmap<k,v>
  insert-with(m, key, value, fn(_old, new) new)

// Insert, combining with an existing value as `combine(old, new)`.
pub fun insert-with( m : hmap<k,v>, key : k, value : v, combine : (v, v) -> v,
                     ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hmap<k,v>
  insert-go(m, key.hash, key, value, combine)

fun insert-go( t : hmap<k,v>, hv : int, key : k, value : v, combine : (v, v) -> v,
               ?(==) : (k,k) -> bool ) : div hmap<k,v>
  match t
    Tip -> Bin(1, 1, hv, [(key, value)], Tip, Tip)
    Bin(_, _, nh, b, l, r) ->
      if hv < nh then balance(nh, b, insert-go(l, hv, key, value, combine), r)
      elif hv > nh then balance(nh, b, l, insert-go(r, hv, key, value, combine))
      else bin(nh, bucket-insert(b, key, value, combine), l, r)

// `bucket-insert` recurses to the tail, so a new key is *appended*: within one
// bucket, iteration yields the least recently inserted key first.
fun bucket-insert( b : list<(k,v)>, key : k, value : v, combine : (v, v) -> v,
                   ?(==) : (k,k) -> bool ) : div list<(k,v)>
  match b
    Nil -> [(key, value)]
    Cons((k0, v0), rest) ->
      if k0 == key
        then Cons((k0, combine(v0, value)), rest)
        else Cons((k0, v0), bucket-insert(rest, key, value, combine))

// Apply `f` to the value for `key`, if there is one.
pub fun update( m : hmap<k,v>, key : k, f : (v) -> v,
                ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hmap<k,v>
  match m.lookup(key)
    Nothing -> m
    Just(v) -> m.insert(key, f(v))

// General single-key update. `f` receives `Nothing` for an absent key and can
// insert, replace, or delete by returning a `maybe`.
pub fun alter( m : hmap<k,v>, key : k, f : (maybe<v>) -> maybe<v>,
               ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hmap<k,v>
  val old = m.lookup(key)
  match (old, f(old))
    (Nothing, Nothing) -> m
    (_, Nothing) -> m.remove(key)
    (_, Just(v)) -> m.insert(key, v)

// ----------------------------------------------------------------------------
// removal
// ----------------------------------------------------------------------------

pub fun remove( m : hmap<k,v>, key : k, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hmap<k,v>
  remove-go(m, key.hash, key)

// The removed value and the remaining map, or `Nothing` when absent.
pub fun pop( m : hmap<k,v>, key : k,
             ?hash : k -> int, ?(==) : (k,k) -> bool )
           : div maybe<(v, hmap<k,v>)>
  match m.lookup(key)
    Nothing -> Nothing
    Just(v) -> Just((v, m.remove(key)))

fun remove-go( t : hmap<k,v>, hv : int, key : k, ?(==) : (k,k) -> bool ) : div hmap<k,v>
  match t
    Tip -> Tip
    Bin(_, _, nh, b, l, r) ->
      if hv < nh then balance(nh, b, remove-go(l, hv, key), r)
      elif hv > nh then balance(nh, b, l, remove-go(r, hv, key))
      else
        val b2 = bucket-remove(b, key)
        if b2.is-nil then glue(l, r) else bin(nh, b2, l, r)

fun bucket-remove( b : list<(k,v)>, key : k, ?(==) : (k,k) -> bool ) : div list<(k,v)>
  match b
    Nil -> Nil
    Cons((k0, v0), rest) ->
      if k0 == key then rest else Cons((k0, v0), bucket-remove(rest, key))

// Join two subtrees whose parent node has gone away.
fun glue( l : hmap<k,v>, r : hmap<k,v> ) : div hmap<k,v>
  match (l, r)
    (Tip, _) -> r
    (_, Tip) -> l
    (Bin(_, _, lh, lb, ll, lr), Bin(_, _, rh, rb, rl, rr)) ->
      if l.weight > r.weight then
        val (h, b, l2) = del-max(lh, lb, ll, lr)
        balance(h, b, l2, r)
      else
        val (h, b, r2) = del-min(rh, rb, rl, rr)
        balance(h, b, l, r2)

// The rightmost node's hash and bucket, and what is left of the subtree.
//
// These take a node's parts rather than a whole `hmap` so that there is no
// empty case to answer for: every caller has already matched a `Bin`.  Written
// over the whole tree they would have to return a `maybe`, and the `Nothing`
// branch in `glue` -- unreachable, but someone has to write it -- would have to
// return the sibling, silently discarding every entry on this side.
fun del-max( h : int, b : list<(k,v)>, l : hmap<k,v>, r : hmap<k,v> )
           : div (int, list<(k,v)>, hmap<k,v>)
  match r
    Tip -> (h, b, l)
    Bin(_, _, rh, rb, rl, rr) ->
      val (mh, mb, r2) = del-max(rh, rb, rl, rr)
      (mh, mb, balance(h, b, l, r2))

fun del-min( h : int, b : list<(k,v)>, l : hmap<k,v>, r : hmap<k,v> )
           : div (int, list<(k,v)>, hmap<k,v>)
  match l
    Tip -> (h, b, r)
    Bin(_, _, lh, lb, ll, lr) ->
      val (mh, mb, l2) = del-min(lh, lb, ll, lr)
      (mh, mb, balance(h, b, l2, r))

// ----------------------------------------------------------------------------
// conversion and iteration
// ----------------------------------------------------------------------------

// All entries, in iteration order (ascending hash; within a bucket, least
// recently inserted first -- `bucket-insert` appends).
pub fun list( m : hmap<k,v> ) : div list<(k,v)>
  list-go(m, [])

fun list-go( t : hmap<k,v>, acc : list<(k,v)> ) : div list<(k,v)>
  match t
    Tip -> acc
    Bin(_, _, _, b, l, r) -> list-go(l, b ++ list-go(r, acc))

pub fun keys( m : hmap<k,v> ) : div list<k>
  m.list.map(fst)

pub fun values( m : hmap<k,v> ) : div list<v>
  m.list.map(snd)

pub fun hmap( xs : list<(k,v)>, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hmap<k,v>
  xs.foldl(Tip, fn(m, kv) m.insert(kv.fst, kv.snd))

pub fun foreach( m : hmap<k,v>, action : (k, v) -> <div|e> () ) : <div|e> ()
  match m
    Tip -> ()
    Bin(_, _, _, b, l, r) ->
      l.foreach(action)
      b.foreach(fn(kv) action(kv.fst, kv.snd))
      r.foreach(action)

// Fold entries in iteration order (ascending hash).
pub fun fold( m : hmap<k,v>, init : a,
              f : (a, k, v) -> <div|e> a ) : <div|e> a
  match m
    Tip -> init
    Bin(_, _, _, b, l, r) ->
      val after-left = l.fold(init, f)
      val after-bucket = b.foldl(after-left, fn(acc, kv) f(acc, kv.fst, kv.snd))
      r.fold(after-bucket, f)

pub fun map( m : hmap<k,v>, f : (v) -> v2 ) : div hmap<k,v2>
  match m
    Tip -> Tip
    Bin(n, w, h, b, l, r) ->
      Bin(n, w, h, b.map(fn(kv) (kv.fst, f(kv.snd))), l.map(f), r.map(f))

pub fun map-with-key( m : hmap<k,v>, f : (k, v) -> v2 ) : div hmap<k,v2>
  match m
    Tip -> Tip
    Bin(n, w, h, b, l, r) ->
      Bin(n, w, h, b.map(fn(kv) (kv.fst, f(kv.fst, kv.snd))),
          l.map-with-key(f), r.map-with-key(f))

pub fun filter( m : hmap<k,v>, pred : (k, v) -> bool,
                ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hmap<k,v>
  m.fold(Tip, fn(acc, k, v) if pred(k, v) then acc.insert(k, v) else acc)

// Transform and filter in one pass.
pub fun filter-map( m : hmap<k,v>, f : (k, v) -> maybe<v2>,
                    ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hmap<k,v2>
  m.fold(Tip, fn(acc, k, v) {
    match f(k, v)
      Nothing -> acc
      Just(v2) -> acc.insert(k, v2)
  })

// ----------------------------------------------------------------------------
// combining
// ----------------------------------------------------------------------------

// Left-biased union: values from `a` win when a key occurs in both maps.
pub fun union( a : hmap<k,v>, b : hmap<k,v>,
               ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hmap<k,v>
  union-with(a, b, fn(left, _right) left)

// Combine matching values as `combine(left, right)`.
pub fun union-with( a : hmap<k,v>, b : hmap<k,v>, combine : (v, v) -> v,
                    ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hmap<k,v>
  b.fold(a, fn(acc, k, right) {
    acc.insert-with(k, right, fn(left, right2) combine(left, right2))
  })

// Left values whose keys occur in both maps.
pub fun intersect( a : hmap<k,v>, b : hmap<k,v2>,
                   ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hmap<k,v>
  intersection-with(a, b, fn(left, _right) left)

pub fun intersection-with( a : hmap<k,v1>, b : hmap<k,v2>,
                           combine : (v1, v2) -> v3,
                           ?hash : k -> int, ?(==) : (k,k) -> bool )
                         : div hmap<k,v3>
  a.fold(Tip, fn(acc, k, left) {
    match b.lookup(k)
      Nothing -> acc
      Just(right) -> acc.insert(k, combine(left, right))
  })

// Remove every key present in `b`.
pub fun difference( a : hmap<k,v>, b : hmap<k,v2>,
                    ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hmap<k,v>
  b.fold(a, fn(acc, k, _v) acc.remove(k))

// ----------------------------------------------------------------------------
// equality
// ----------------------------------------------------------------------------

// Two maps are equal when they hold the same key/value pairs, regardless of
// the shape of the trees or the order within buckets.
pub fun (==)( m1 : hmap<k,v>, m2 : hmap<k,v>,
              ?hash : k -> int, ?key/(==) : (k,k) -> bool,
              ?val/(==) : (v,v) -> bool ) : div bool
  if m1.size != m2.size then False
  else m1.list.all fn(kv)
         match m2.lookup(kv.fst)
           Just(v2) -> val/(==)(kv.snd, v2)
           Nothing  -> False

pub fun show( m : hmap<k,v>, ?kshow : k -> string, ?vshow : v -> string ) : div string
  "{" ++ m.list.map(fn(kv) kshow(kv.fst) ++ ": " ++ vshow(kv.snd)).join(", ") ++ "}"

// ----------------------------------------------------------------------------
// invariants (used by the tests)
// ----------------------------------------------------------------------------

// Is the weight-balance invariant intact, are both stored counts what they
// claim to be, and are hashes strictly increasing left to right?  Exposed so
// tests can check the tree after every operation rather than only checking
// observable behaviour.
//
// The balance clause is on `nodes`; the entry count is only checked for
// consistency, since no rotation can move an entry between buckets.  A test
// that only ever uses a collision-free hash cannot tell the two apart, so
// `map-test.kk` checks this under a colliding hash as well.
pub fun is-balanced( m : hmap<k,v> ) : div bool
  match m
    Tip -> True
    Bin(n, w, _, b, l, r) ->
      val ls = l.weight
      val rs = r.weight
      n == b.length + l.size + r.size &&
      w == 1 + ls + rs &&
      b.is-cons &&
      (ls + rs <= 1 || (ls <= delta * rs && rs <= delta * ls)) &&
      l.is-balanced && r.is-balanced

pub fun is-ordered( m : hmap<k,v> ) : div bool
  node-hashes(m).is-strictly-increasing

fun node-hashes( t : hmap<k,v> ) : div list<int>
  match t
    Tip -> []
    Bin(_, _, h, _, l, r) -> node-hashes(l) ++ [h] ++ node-hashes(r)

fun is-strictly-increasing( xs : list<int> ) : div bool
  match xs
    Cons(a, Cons(b, rest)) -> a < b && is-strictly-increasing(Cons(b, rest))
    _ -> True
