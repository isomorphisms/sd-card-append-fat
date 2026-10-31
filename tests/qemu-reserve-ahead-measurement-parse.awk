# Parse one appendFAT measurement receipt and its bounded kernel record.
# The receipt and kernel record are separate files.  Console output is not input.

function fail(message) {
    if (!failed) {
        print "appendfat measurement parse failure: " message > "/dev/stderr"
    }
    failed = 1
    exit 1
}

function numeric(value) {
    return value ~ /^[0-9]+$/
}

function record_value(key,    field_index, pair, matches, value) {
    matches = 0
    value = ""
    for (field_index = 1; field_index <= NF; field_index++) {
        split($field_index, pair, "=")
        if (pair[1] == key) {
            matches++
            value = pair[2]
        }
    }
    if (matches != 1 || value == "") {
        fail("missing or duplicate " key " in: " $0)
    }
    return value
}

function require_number(key,    value) {
    value = record_value(key)
    if (!numeric(value)) {
        fail("non-numeric " key " in: " $0)
    }
    return value
}

function receipt_value(key) {
    if (!(key in receipt)) {
        fail("missing receipt field " key)
    }
    return receipt[key]
}

function require_receipt_number(key,    value) {
    value = receipt_value(key)
    if (!numeric(value)) {
        fail("non-numeric receipt field " key)
    }
    return value
}

function validate_receipt(    expected_bytes, expected_blocks) {
    if (receipt_records != 1) {
        fail("expected one receipt record")
    }
    if (receipt_value("format") != "v1") {
        fail("unsupported receipt format")
    }
    if (receipt_value("run_id") != expected_run_id) {
        fail("receipt run id does not match requested run")
    }
    if (receipt_value("variant") != expected_variant) {
        fail("receipt variant does not match requested variant")
    }
    if (require_receipt_number("policy_clusters") != expected_policy_clusters ||
        require_receipt_number("target_clusters") != 64 ||
        require_receipt_number("chunk_bytes") != 97 ||
        require_receipt_number("content_byte") != 90) {
        fail("receipt workload parameters differ from the fixed comparison")
    }
    expected_bytes = require_receipt_number("target_clusters") * require_receipt_number("cluster_bytes")
    expected_blocks = expected_bytes / 512
    if (require_receipt_number("target_bytes") != expected_bytes ||
        require_receipt_number("logical_size") != expected_bytes ||
        require_receipt_number("logical_blocks") != expected_blocks) {
        fail("receipt logical geometry does not match the completed workload")
    }
    require_receipt_number("vda_write_ops")
    require_receipt_number("vda_write_sectors")
}

BEGIN {
    if (expected_alloc_calls != "" && !numeric(expected_alloc_calls)) {
        fail("non-numeric expected allocation record count")
    }
}

NR == FNR {
    if ($0 == "") {
        next
    }
    if ($1 != "APPENDFAT_APPEND_RECEIPT") {
        fail("non-receipt data in receipt file")
    }
    receipt_records++
    for (field = 2; field <= NF; field++) {
        split($field, pair, "=")
        if (pair[1] == "" || pair[2] == "") {
            fail("malformed receipt field")
        }
        if (pair[1] in receipt) {
            fail("duplicate receipt field " pair[1])
        }
        receipt[pair[1]] = pair[2]
    }
    next
}

FNR == 1 {
    validate_receipt()
}

/APPENDFAT_MEASURE_BEGIN/ {
    if (inside || begin_count != 0) {
        fail("duplicate or nested measurement begin")
    }
    if (record_value("run_id") != expected_run_id ||
        record_value("variant") != expected_variant ||
        require_number("policy_clusters") != expected_policy_clusters) {
        fail("measurement begin identity mismatch")
    }
    begin_count++
    inside = 1
    next
}

/APPENDFAT_MEASURE_END/ {
    if (!inside || end_count != 0 || record_value("run_id") != expected_run_id) {
        fail("missing, duplicate, or cross-run measurement end")
    }
    end_count++
    inside = 0
    next
}

/APPENDFAT_(APPEND|ALLOC)_METRIC reserve_start/ {
    if (!inside) {
        next
    }
    if (require_number("requested_clusters") != expected_policy_clusters) {
        fail("compiled reservation policy differs from requested variant")
    }
    reserve_calls++
    next
}

/APPENDFAT_ALLOC_METRIC/ {
    if (!inside) {
        next
    }
    if ($0 ~ / alloc requested=/) {
        require_number("requested")
        require_number("allocated")
        allocator_fat_updates += require_number("fat_updates")
        fat_buffer_refs += require_number("fat_buffers")
        mirror_buffer_copies += require_number("mirror_buffers")
        fsinfo_dirty_calls += require_number("fsinfo_dirty_calls")
        if (require_number("result") != 0) {
            fail("allocator reported failure")
        }
        alloc_calls++
    } else if ($0 ~ / attach clusters=/) {
        require_number("clusters")
        tail_links += require_number("tail_link")
        fat_buffer_refs += require_number("fat_buffers")
        mirror_buffer_copies += require_number("mirror_buffers")
        attach_calls++
    } else {
        fail("unknown metric record inside measurement interval")
    }
}

END {
    if (failed) {
        exit 1
    }
    validate_receipt()
    if (begin_count != 1 || end_count != 1 || inside ||
        reserve_calls == 0 || alloc_calls == 0 || attach_calls == 0) {
        fail("incomplete measurement interval")
    }
    if (reserve_calls != alloc_calls || alloc_calls != attach_calls) {
        fail("reservation, allocation, and attachment counts disagree")
    }
    if (expected_alloc_calls != "" && alloc_calls != expected_alloc_calls) {
        fail("allocation record count does not match the completed workload")
    }
    printf "variant=%s run_id=%s policy_clusters=%s reserve_calls=%d alloc_calls=%d attach_calls=%d fat_updates=%d fat_buffer_refs=%d mirror_buffer_copies=%d fsinfo_dirty_calls=%d write_ops=%s write_sectors=%s logical_size=%s logical_blocks=%s cluster_bytes=%s target_bytes=%s\n", \
        expected_variant, expected_run_id, expected_policy_clusters,
        reserve_calls, alloc_calls, attach_calls,
        allocator_fat_updates + tail_links,
        fat_buffer_refs, mirror_buffer_copies, fsinfo_dirty_calls,
        receipt["vda_write_ops"], receipt["vda_write_sectors"],
        receipt["logical_size"], receipt["logical_blocks"],
        receipt["cluster_bytes"], receipt["target_bytes"]
}
