# rules

What broke -> the rule.

- store.expect held BentoML's "Multiple versions found" list in btrfs directory order; the ext4 runner listed it reversed and the drift gate failed (mojo-libs #6) -> output whose order comes from the filesystem is compared canonicalized (sorted), on the oracle and the Mojo side alike.
