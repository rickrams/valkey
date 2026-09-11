proc info_field {info field} {
    foreach line [split $info "\n"] {
        if {[string match "$field:*" $line]} {
            return [string trim [lindex [split $line ":"] 1]]
        }
    }
    return ""
}

proc get_keys_with_volatile_items {r} {
    set line [$r info keyspace]
    set match [regexp -inline {keys_with_volatile_items=([\d]+)} $line]
    if {[llength $match] == 2} {
        return [lindex $match 1]
    } else {
        return 0
    }
}

# Run the full ZSET field-TTL battery for a given target encoding by forcing
# the listpack threshold. 'encoding' is "listpack" or "btree".
proc test_zset_ttl {encoding} {
    if {$encoding eq "listpack"} {
        r config set zset-max-listpack-entries 128
        r config set zset-max-listpack-value 64
    } elseif {$encoding eq "btree"} {
        r config set zset-max-listpack-entries 0
    } else {
        error "unknown encoding $encoding"
    }

    test "ZEXPIRE/ZTTL basics ($encoding)" {
        r del z
        r zadd z 1 a 2 b 3 c
        assert_encoding $encoding z
        # No TTL yet.
        assert_equal {-1 -1 -1} [r zttl z MEMBERS 3 a b c]
        # Set a TTL on b.
        assert_equal {1} [r zexpire z 100 MEMBERS 1 b]
        assert_range [lindex [r zttl z MEMBERS 1 b] 0] 90 100
        assert_range [lindex [r zpttl z MEMBERS 1 b] 0] 90000 100000
        # a and c untouched.
        assert_equal {-1 -1} [r zttl z MEMBERS 2 a c]
    }

    test "ZTTL/ZEXPIRE on missing member or key ($encoding)" {
        r del z
        r zadd z 1 a
        assert_equal {-2} [r zttl z MEMBERS 1 nope]
        assert_equal {-2} [r zttl missingkey MEMBERS 1 a]
        assert_equal {-2} [r zexpire z 100 MEMBERS 1 nope]
        assert_equal {-2} [r zexpire missingkey 100 MEMBERS 1 a]
    }

    test "ZEXPIREAT and ZEXPIRETIME ($encoding)" {
        r del z
        r zadd z 1 a
        set at [expr {[clock seconds] + 100}]
        assert_equal {1} [r zexpireat z $at MEMBERS 1 a]
        assert_equal [list $at] [r zexpiretime z MEMBERS 1 a]
        set atms [expr {[clock milliseconds] + 100000}]
        assert_equal {1} [r zpexpireat z $atms MEMBERS 1 a]
        assert_equal [list $atms] [r zpexpiretime z MEMBERS 1 a]
    }

    test "ZEXPIRE NX/XX/GT/LT conditions ($encoding)" {
        r del z
        r zadd z 1 a
        # NX: only if no TTL.
        assert_equal {1} [r zexpire z 100 NX MEMBERS 1 a]
        assert_equal {0} [r zexpire z 200 NX MEMBERS 1 a]
        # XX: only if a TTL exists.
        assert_equal {1} [r zexpire z 300 XX MEMBERS 1 a]
        # GT: only if new > current.
        assert_equal {0} [r zexpire z 100 GT MEMBERS 1 a]
        assert_equal {1} [r zexpire z 100000 GT MEMBERS 1 a]
        # LT: only if new < current.
        assert_equal {1} [r zexpire z 50 LT MEMBERS 1 a]
        assert_equal {0} [r zexpire z 50000 LT MEMBERS 1 a]
    }

    test "ZEXPIRE with past time deletes member (returns 2) ($encoding)" {
        r del z
        r zadd z 1 a 2 b
        assert_equal {2} [r zexpire z 0 MEMBERS 1 a]
        assert_equal {} [r zscore z a]
        assert_equal 2 [r zscore z b]
        assert_equal 1 [r zcard z]
    }

    test "ZEXPIRE past time on last member deletes the key ($encoding)" {
        r del z
        r zadd z 1 only
        assert_equal {2} [r zexpire z 0 MEMBERS 1 only]
        assert_equal 0 [r exists z]
    }

    test "ZPERSIST ($encoding)" {
        r del z
        r zadd z 1 a 2 b
        r zexpire z 100 MEMBERS 1 a
        # remove existing TTL -> 1; no TTL -> -1; missing -> -2
        assert_equal {1} [r zpersist z MEMBERS 1 a]
        assert_equal {-1} [r zpersist z MEMBERS 1 a]
        assert_equal {-1} [r zpersist z MEMBERS 1 b]
        assert_equal {-2} [r zpersist z MEMBERS 1 nope]
        assert_equal {-1} [r zttl z MEMBERS 1 a]
    }

    test "TTL persists across ZADD score update ($encoding)" {
        r del z
        r zadd z 1 a
        r zexpire z 1000 MEMBERS 1 a
        set t0 [lindex [r zttl z MEMBERS 1 a] 0]
        assert_range $t0 900 1000
        # Update score; TTL must survive.
        r zadd z 5 a
        assert_equal 5 [r zscore z a]
        assert_range [lindex [r zttl z MEMBERS 1 a] 0] 900 1000
        # ZINCRBY too.
        r zincrby z 2 a
        assert_range [lindex [r zttl z MEMBERS 1 a] 0] 900 1000
    }

    test "Lazy hiding: ZSCORE/ZMSCORE hide expired member ($encoding)" {
        r del z
        r zadd z 1 a 2 b 3 c
        r zpexpire z 20 MEMBERS 1 b
        after 60
        assert_equal {} [r zscore z b]
        assert_equal {1 {} 3} [r zmscore z a b c]
        assert_equal {-2} [r zttl z MEMBERS 1 b]
    }

    test "Lazy hiding: ZRANGEBYSCORE/ZRANGEBYLEX skip expired, honor LIMIT ($encoding)" {
        r del z
        r zadd z 1 a 2 b 3 c 4 d 5 e
        r zpexpire z 20 MEMBERS 1 c
        after 60
        assert_equal {a b d e} [r zrangebyscore z 0 10]
        assert_equal {e d b a} [r zrevrangebyscore z 10 0]
        assert_equal {a b d e} [r zrangebylex z - +]
        # Expired c must not consume a LIMIT slot.
        assert_equal {a b} [r zrangebyscore z 0 10 LIMIT 0 2]
        assert_equal {b d} [r zrangebyscore z 0 10 LIMIT 1 2]
    }

    test "Active expiration reaps members and deletes empty key ($encoding)" {
        r del z
        r zadd z 1 a 2 b 3 c
        set base [info_field [r info stats] expired_fields]
        r zpexpire z 20 MEMBERS 2 a b
        wait_for_condition 50 20 {
            [r zcard z] == 1 &&
            [info_field [r info stats] expired_fields] >= [expr {$base + 2}]
        } else {
            fail "active expiry of zset members did not occur"
        }
        assert_equal {c} [r zrange z 0 -1]
        # Expire the last one -> key removed.
        r zpexpire z 20 MEMBERS 1 c
        wait_for_condition 50 20 {
            [r exists z] == 0
        } else {
            fail "empty zset key was not deleted after active expiry"
        }
    }

    test "ZREM of last volatile member untracks the key ($encoding)" {
        r del z
        r zadd z 1 a 2 b
        r zexpire z 100000 MEMBERS 1 a
        assert_equal 1 [get_keys_with_volatile_items r]
        # Remove the only volatile member; a non-volatile member remains.
        r zrem z a
        assert_equal 0 [get_keys_with_volatile_items r]
        # The active-expire cycle must not trip over a stale tracked key.
        after 150
        assert_equal PONG [r ping] ;# server still alive
        assert_equal {b} [r zrange z 0 -1]
    }

    test "ZREMRANGEBYRANK/BYSCORE with volatile members ($encoding)" {
        foreach cmd {byrank byscore} {
            r del z
            r zadd z 1 a 2 b 3 c 4 d
            r zexpire z 100000 MEMBERS 2 b c
            assert_equal 1 [get_keys_with_volatile_items r]
            if {$cmd eq "byrank"} {
                r zremrangebyrank z 1 2 ;# remove b,c (the volatile ones)
            } else {
                r zremrangebyscore z 2 3 ;# remove b,c
            }
            assert_equal {a d} [r zrange z 0 -1]
            # b,c were the only volatile members -> key untracked.
            assert_equal 0 [get_keys_with_volatile_items r]
            assert_equal {-1 -1} [r zttl z MEMBERS 2 a d]
            after 120
            assert_equal PONG [r ping]
        }
    }

    test "ZPOPMIN/ZPOPMAX preserve volatile tracking ($encoding)" {
        r del z
        r zadd z 1 a 2 b 3 c
        r zexpire z 100000 MEMBERS 1 a
        r zpopmin z ;# pops a (the volatile one)
        assert_equal 0 [get_keys_with_volatile_items r]
        after 120
        assert_equal PONG [r ping]
    }

    r config set zset-max-listpack-entries 128
    r config set zset-max-listpack-value 64
}

start_server {tags {"zsetexpire external:skip"}} {
    foreach encoding {listpack btree} {
        test_zset_ttl $encoding
    }

    test "TTL survives listpack -> btree conversion" {
        r config set zset-max-listpack-entries 128
        r del z
        r zadd z 1 a 2 b
        r zexpire z 10000 MEMBERS 1 b
        assert_encoding listpack z
        # Grow past the threshold to force conversion.
        for {set i 0} {$i < 200} {incr i} { r zadd z $i m$i }
        assert_encoding btree z
        assert_range [lindex [r zttl z MEMBERS 1 b] 0] 9900 10000
    }

    test "COPY preserves member TTLs (listpack and btree)" {
        foreach {enc entries} {listpack 128 btree 0} {
            r config set zset-max-listpack-entries $entries
            r del src dst
            r zadd src 1 a 2 b 3 c
            r zexpire src 100000 MEMBERS 1 b
            assert_encoding $enc src
            assert_equal 1 [r copy src dst]
            assert_encoding $enc dst
            assert_range [lindex [r zttl dst MEMBERS 1 b] 0] 99000 100000
            assert_equal {-1 -1} [r zttl dst MEMBERS 2 a c]
        }
        r config set zset-max-listpack-entries 128
    }

    test "DUMP/RESTORE preserves member TTLs (listpack and btree)" {
        foreach {enc entries} {listpack 128 btree 0} {
            r config set zset-max-listpack-entries $entries
            r del src dst
            r zadd src 1 a 2 b 3 c
            r zexpire src 100000 MEMBERS 1 b
            assert_encoding $enc src
            set payload [r dump src]
            r restore dst 0 $payload
            assert_encoding $enc dst
            assert_equal 3 [r zcard dst]
            assert_range [lindex [r zttl dst MEMBERS 1 b] 0] 99000 100000
            assert_equal {-1} [r zttl dst MEMBERS 1 a]
        }
        r config set zset-max-listpack-entries 128
    }

    test "keys_with_volatile_items tracking" {
        r config set zset-max-listpack-entries 128
        r flushall
        assert_equal 0 [get_keys_with_volatile_items r]
        r zadd z 1 a
        r zexpire z 1000 MEMBERS 1 a
        assert_equal 1 [get_keys_with_volatile_items r]
        r zpersist z MEMBERS 1 a
        assert_equal 0 [get_keys_with_volatile_items r]
    }

    test "Argument validation" {
        r del z
        r zadd z 1 a 2 b
        assert_error "*nummembers*" {r zexpire z 100 MEMBERS 3 a b}
        assert_error "*nummembers*" {r zexpire z 100 MEMBERS 0 a}
        assert_error "*not an integer*" {r zexpire z notanumber MEMBERS 1 a}
        # Wrong type.
        r del str
        r set str foo
        assert_error "*WRONGTYPE*" {r zexpire str 100 MEMBERS 1 a}
        assert_error "*WRONGTYPE*" {r zttl str MEMBERS 1 a}
    }

    test "Keyspace notifications: zexpire, zpersist, zexpired, del" {
        r config set zset-max-listpack-entries 128
        r config set notify-keyspace-events KEA
        r flushall
        r zadd z 1 a 2 b
        set rd [valkey_deferring_client]
        assert_equal {1} [psubscribe $rd {__keyevent@*__:*}]

        r zexpire z 1000 MEMBERS 1 a
        assert_equal {pmessage __keyevent@*__:* __keyevent@9__:zexpire z} [$rd read]

        r zpersist z MEMBERS 1 a
        assert_equal {pmessage __keyevent@*__:* __keyevent@9__:zpersist z} [$rd read]

        # Active-expire both -> zexpired then del.
        r zpexpire z 20 MEMBERS 2 a b
        assert_equal {pmessage __keyevent@*__:* __keyevent@9__:zexpire z} [$rd read]
        assert_equal {pmessage __keyevent@*__:* __keyevent@9__:zexpired z} [$rd read]
        assert_equal {pmessage __keyevent@*__:* __keyevent@9__:del z} [$rd read]

        $rd close
    }
}

start_server {tags {"zsetexpire needs:debug external:skip"} overrides {save ""}} {
    foreach {enc entries} {listpack 128 btree 0} {
        test "RDB round-trip preserves member TTLs ($enc)" {
            r config set zset-max-listpack-entries $entries
            r del z
            r zadd z 1 a 2 b 3 c
            r zexpire z 100000 MEMBERS 1 b
            r zpexpireat z 99999999999999 MEMBERS 1 c
            assert_encoding $enc z
            r debug reload
            assert_encoding $enc z
            assert_equal 3 [r zcard z]
            assert_equal {-1} [r zttl z MEMBERS 1 a]
            assert_range [lindex [r zttl z MEMBERS 1 b] 0] 99000 100000
            assert_equal {99999999999999} [r zpexpiretime z MEMBERS 1 c]
            # Tracking re-established so active expiry still works after reload.
            assert_equal 1 [get_keys_with_volatile_items r]
        }
    }
    r config set zset-max-listpack-entries 128
}

start_server {tags {"zsetexpire external:skip"}} {
    start_server {tags {"needs:repl external:skip"}} {
        set primary [srv -1 client]
        set primary_host [srv -1 host]
        set primary_port [srv -1 port]
        set replica [srv 0 client]

        $replica replicaof $primary_host $primary_port
        wait_for_condition 50 100 {
            [lindex [$replica role] 0] eq {slave} &&
            [string match {*master_link_status:up*} [$replica info replication]]
        } else {
            fail "Can't turn the instance into a replica"
        }

        foreach {enc entries} {listpack 128 btree 0} {
            test "Full sync carries member TTLs ($enc)" {
                $primary flushall
                # Encoding is chosen per-server by local config (not replicated),
                # so set the threshold on both to compare encodings.
                $primary config set zset-max-listpack-entries $entries
                $replica config set zset-max-listpack-entries $entries
                set e2 [expr {[clock milliseconds] + 50000}]
                set e3 [expr {[clock milliseconds] + 70000}]
                $primary zadd z 1 a 2 b 3 c
                $primary zpexpireat z $e2 MEMBERS 1 b
                $primary zpexpireat z $e3 MEMBERS 1 c
                assert_equal $enc [$primary object encoding z]
                wait_for_ofs_sync $primary $replica
                assert_equal $enc [$replica object encoding z]
                assert_equal [list $e2] [$replica zpexpiretime z MEMBERS 1 b]
                assert_equal [list $e3] [$replica zpexpiretime z MEMBERS 1 c]
                assert_equal {-1} [$replica zttl z MEMBERS 1 a]
            }
        }

        test "ZEXPIRE/ZEXPIREAT propagate an absolute expiry consistently" {
            $primary flushall
            set future [expr {[clock milliseconds] + 5000}]
            $primary zadd z 1 a 2 b 3 c
            $primary zpexpireat z $future MEMBERS 1 a
            $primary zexpire z 5 MEMBERS 1 b
            $primary zexpireat z [expr {([clock milliseconds] + 5000) / 1000}] MEMBERS 1 c
            wait_for_ofs_sync $primary $replica
            foreach m {a b c} {
                assert_equal [$primary zpexpiretime z MEMBERS 1 $m] [$replica zpexpiretime z MEMBERS 1 $m]
            }
        }

        test "Member expired on primary is removed on replica (active)" {
            $primary flushall
            $primary zadd z 1 a 2 keep
            $primary zpexpire z 50 MEMBERS 1 a
            wait_for_ofs_sync $primary $replica
            # Wait for the primary's active-expire cycle to physically reap 'a'
            # (zcard is eventually-consistent, so it drops only after reaping,
            # not on lazy hiding), which propagates a ZREM to the replica.
            wait_for_condition 100 50 {
                [$primary zcard z] == 1
            } else {
                fail "primary did not actively reap the expired member"
            }
            wait_for_ofs_sync $primary $replica
            assert_equal {keep} [$replica zrange z 0 -1]
            assert_equal {} [$replica zscore z a]
        }

        test "ZEXPIRE with past time propagates member deletion to replica" {
            $primary flushall
            $primary zadd z 1 a 2 b
            assert_equal {2} [$primary zexpire z 0 MEMBERS 1 a]
            wait_for_ofs_sync $primary $replica
            assert_equal {} [$replica zscore z a]
            assert_equal 2 [$replica zscore z b]
        }

        test "Replica retains member and TTL before expiration" {
            $primary flushall
            $primary zadd z 1 a
            $primary zpexpire z 60000 MEMBERS 1 a
            wait_for_ofs_sync $primary $replica
            set rttl [lindex [$replica zpttl z MEMBERS 1 a] 0]
            assert {$rttl > 0}
            assert {$rttl <= 60000}
        }

        test "Last member expiry deletes the key on replica" {
            $primary flushall
            $primary zadd z 1 only
            $primary zpexpire z 50 MEMBERS 1 only
            wait_for_condition 100 50 {
                [$primary exists z] == 0
            } else {
                fail "key not deleted on primary"
            }
            wait_for_ofs_sync $primary $replica
            wait_for_condition 100 50 {
                [$replica exists z] == 0
            } else {
                fail "key not deleted on replica"
            }
        }
    }
}
