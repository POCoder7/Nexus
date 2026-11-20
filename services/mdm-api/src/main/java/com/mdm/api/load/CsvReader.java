package com.mdm.api.load;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * A small RFC 4180 CSV reader for the hackathon files (ADR-046; no new dependency): comma-separated, fields in double
 * quotes may hold commas, quotes ("" inside quotes) and line breaks; CRLF or LF; a UTF-8 byte-order mark is dropped;
 * blank lines are skipped. Values are returned as written; the staging function trims them.
 */
public final class CsvReader {

    private CsvReader() {
    }

    /** Every non-blank line as its fields; the first one is the header. */
    public static List<List<String>> read(byte[] bytes) {
        String text = new String(bytes, StandardCharsets.UTF_8);
        if (text.startsWith("﻿")) {
            text = text.substring(1);
        }
        List<List<String>> rows = new ArrayList<>();
        List<String> row = new ArrayList<>();
        StringBuilder field = new StringBuilder();
        boolean quoted = false;
        boolean fieldStarted = false;
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (quoted) {
                if (c == '"') {
                    if (i + 1 < text.length() && text.charAt(i + 1) == '"') {
                        field.append('"');
                        i++;
                    } else {
                        quoted = false;
                    }
                } else {
                    field.append(c);
                }
            } else if (c == '"' && !fieldStarted) {
                quoted = true;
                fieldStarted = true;
            } else if (c == ',') {
                row.add(field.toString());
                field.setLength(0);
                fieldStarted = false;
            } else if (c == '\n' || c == '\r') {
                if (c == '\r' && i + 1 < text.length() && text.charAt(i + 1) == '\n') {
                    i++;
                }
                endLine(rows, row, field, fieldStarted);
                row = new ArrayList<>();
                field.setLength(0);
                fieldStarted = false;
            } else {
                field.append(c);
                fieldStarted = true;
            }
        }
        if (quoted) {
            throw new IllegalArgumentException("A quoted field is not closed before the end of the file");
        }
        endLine(rows, row, field, fieldStarted);
        return rows;
    }

    private static void endLine(List<List<String>> rows, List<String> row, StringBuilder field, boolean fieldStarted) {
        if (row.isEmpty() && field.isEmpty() && !fieldStarted) {
            return;   // a blank line
        }
        row.add(field.toString());
        rows.add(row);
    }
}
