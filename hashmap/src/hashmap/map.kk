/* A persistent hash map.

   ## Representation

   A weight-balanced binary search tree ordered by the *hash* of the key, with
   a bucket at each node holding every entry whose key hashes to that value.
   This gives O(log n) operations without needing bitwise arithmetic on Koka's
   arbitrary-precision `:int`, and it is persistent: an update shares all the
   structure it did not touch.

   ## Hash requirements

   A key type supplies `?hash : k -> int` and `?(==) : (k,k) -> bool`.  The
   only requirement is the usual one:

   > if `a == b` then `hash(a) == hash(b)`

   A hash need not be non-negative and need not be well distributed for the
   map to be *correct*; poor distribution only degrades a lookup within one
   bucket to a linear scan of that bucket.

   ## Iteration order

   Ascending hash value; within one bucket, most recently inserted first.
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
   shares the rest.  When a map is *uniquely* referenced, Koka's reuse
   analysis can write those nodes in place instead of allocating them, so a
   loop that threads one map through repeated inserts does not allocate a new
   spine each time.  Holding a second reference (for example keeping the old
   map) disables that and the update allocates, which is exactly the cost of
   persistence.
*/
module hashmap/map

// A map from `k` to `v`.
pub type hmap<k,v>
  Tip
  // `size` counts entries, not nodes, so `size` is O(1).
  Bin( size : int, hash : int, bucket : list<(k,v)>, left : hmap<k,v>, right : hmap<k,v> )

pub fun empty() : hmap<k,v>
  Tip

pub fun is-empty( m : hmap<k,v> ) : bool
  match m
    Tip -> True
    _   -> False

pub fun size( m : hmap<k,v> ) : int
  match m
    Tip                  -> 0
    Bin(n, _, _, _, _)   -> n

// ----------------------------------------------------------------------------
// balancing
//
// The standard weight-balanced scheme: a subtree may be at most `delta` times
// heavier than its sibling, and a `ratio` decides between a single and a
// double rotation.
// ----------------------------------------------------------------------------

val delta : int = 3
val ratio : int = 2

fun node-size( m : hmap<k,v> ) : int
  m.size

fun bin( h : int, b : list<(k,v)>, l : hmap<k,v>, r : hmap<k,v> ) : hmap<k,v>
  Bin(b.length + l.node-size + r.node-size, h, b, l, r)

// Rebuild a node after one side changed by at most one entry.
fun balance( h : int, b : list<(k,v)>, l : hmap<k,v>, r : hmap<k,v> ) : hmap<k,v>
  val ls = l.node-size
  val rs = r.node-size
  if ls + rs <= 1 then bin(h, b, l, r)
  elif rs > delta * ls then rotate-left(h, b, l, r)
  elif ls > delta * rs then rotate-right(h, b, l, r)
  else bin(h, b, l, r)

fun rotate-left( h : int, b : list<(k,v)>, l : hmap<k,v>, r : hmap<k,v> ) : hmap<k,v>
  match r
    Bin(_, rh, rb, rl, rr) ->
      if rl.node-size < ratio * rr.node-size
        then bin(rh, rb, bin(h, b, l, rl), rr)                     // single
        else match rl                                              // double
               Bin(_, rlh, rlb, rll, rlr) ->
                 bin(rlh, rlb, bin(h, b, l, rll), bin(rh, rb, rlr, rr))
               Tip -> bin(h, b, l, r)
    Tip -> bin(h, b, l, r)

fun rotate-right( h : int, b : list<(k,v)>, l : hmap<k,v>, r : hmap<k,v> ) : hmap<k,v>
  match l
    Bin(_, lh, lb, ll, lr) ->
      if lr.node-size < ratio * ll.node-size
        then bin(lh, lb, ll, bin(h, b, lr, r))                     // single
        else match lr                                              // double
               Bin(_, lrh, lrb, lrl, lrr) ->
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
    Bin(_, nh, b, l, r) ->
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
    Tip -> Bin(1, hv, [(key, value)], Tip, Tip)
    Bin(_, nh, b, l, r) ->
      if hv < nh then balance(nh, b, insert-go(l, hv, key, value, combine), r)
      elif hv > nh then balance(nh, b, l, insert-go(r, hv, key, value, combine))
      else bin(nh, bucket-insert(b, key, value, combine), l, r)

// New entries go to the front of the bucket, so within a bucket iteration
// yields the most recently inserted key first.
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

// ----------------------------------------------------------------------------
// removal
// ----------------------------------------------------------------------------

pub fun remove( m : hmap<k,v>, key : k, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hmap<k,v>
  remove-go(m, key.hash, key)

fun remove-go( t : hmap<k,v>, hv : int, key : k, ?(==) : (k,k) -> bool ) : div hmap<k,v>
  match t
    Tip -> Tip
    Bin(_, nh, b, l, r) ->
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
    _ ->
      if l.node-size > r.node-size then
        match del-max(l)
          Just((h, b, l2)) -> balance(h, b, l2, r)
          Nothing          -> r
      else
        match del-min(r)
          Just((h, b, r2)) -> balance(h, b, l, r2)
          Nothing          -> l

fun del-max( t : hmap<k,v> ) : div maybe<(int, list<(k,v)>, hmap<k,v>)>
  match t
    Tip -> Nothing
    Bin(_, h, b, l, Tip) -> Just((h, b, l))
    Bin(_, h, b, l, r) ->
      match del-max(r)
        Just((mh, mb, r2)) -> Just((mh, mb, balance(h, b, l, r2)))
        Nothing            -> Nothing

fun del-min( t : hmap<k,v> ) : div maybe<(int, list<(k,v)>, hmap<k,v>)>
  match t
    Tip -> Nothing
    Bin(_, h, b, Tip, r) -> Just((h, b, r))
    Bin(_, h, b, l, r) ->
      match del-min(l)
        Just((mh, mb, l2)) -> Just((mh, mb, balance(h, b, l2, r)))
        Nothing            -> Nothing

// ----------------------------------------------------------------------------
// conversion and iteration
// ----------------------------------------------------------------------------

// All entries, in iteration order (ascending hash; within a bucket, most
// recently inserted first).
pub fun list( m : hmap<k,v> ) : div list<(k,v)>
  list-go(m, [])

fun list-go( t : hmap<k,v>, acc : list<(k,v)> ) : div list<(k,v)>
  match t
    Tip -> acc
    Bin(_, _, b, l, r) -> list-go(l, b ++ list-go(r, acc))

pub fun keys( m : hmap<k,v> ) : div list<k>
  m.list.map(fst)

pub fun values( m : hmap<k,v> ) : div list<v>
  m.list.map(snd)

pub fun hmap( xs : list<(k,v)>, ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hmap<k,v>
  xs.foldl(Tip, fn(m, kv) m.insert(kv.fst, kv.snd))

pub fun foreach( m : hmap<k,v>, action : (k, v) -> <div|e> () ) : <div|e> ()
  m.list.foreach(fn(kv) action(kv.fst, kv.snd))

pub fun map( m : hmap<k,v>, f : (v) -> v2 ) : div hmap<k,v2>
  match m
    Tip -> Tip
    Bin(n, h, b, l, r) ->
      Bin(n, h, b.map(fn(kv) (kv.fst, f(kv.snd))), l.map(f), r.map(f))

pub fun filter( m : hmap<k,v>, pred : (k, v) -> bool,
                ?hash : k -> int, ?(==) : (k,k) -> bool ) : div hmap<k,v>
  m.list.foldl(Tip, fn(acc, kv) if pred(kv.fst, kv.snd) then acc.insert(kv.fst, kv.snd) else acc)

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

// Is the weight-balance invariant intact, and are hashes strictly increasing
// left to right?  Exposed so tests can check the tree after every operation
// rather than only checking observable behaviour.
pub fun is-balanced( m : hmap<k,v> ) : div bool
  match m
    Tip -> True
    Bin(n, _, b, l, r) ->
      val ls = l.node-size
      val rs = r.node-size
      n == b.length + ls + rs &&
      (ls + rs <= 1 || (ls <= delta * rs && rs <= delta * ls)) &&
      l.is-balanced && r.is-balanced

pub fun is-ordered( m : hmap<k,v> ) : div bool
  node-hashes(m).is-strictly-increasing

fun node-hashes( t : hmap<k,v> ) : div list<int>
  match t
    Tip -> []
    Bin(_, h, _, l, r) -> node-hashes(l) ++ [h] ++ node-hashes(r)

fun is-strictly-increasing( xs : list<int> ) : div bool
  match xs
    Cons(a, Cons(b, rest)) -> a < b && is-strictly-increasing(Cons(b, rest))
    _ -> True
