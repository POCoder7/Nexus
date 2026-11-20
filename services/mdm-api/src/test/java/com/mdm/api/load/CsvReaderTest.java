package com.mdm.api.load;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** The CSV reader for the hackathon files (ADR-046): quotes, commas and line breaks in fields, CRLF, BOM, blank lines. */
class CsvReaderTest {

    private static List<List<String>> read(String text) {
        return CsvReader.read(text.getBytes(StandardCharsets.UTF_8));
    }

    @Test
    void readsPlainAndQuotedFields() {
        assertThat(read("a,b,c\r\n1,\"two, with comma\",\"say \"\"hi\"\"\"\n"))
                .containsExactly(List.of("a", "b", "c"), List.of("1", "two, with comma", "say \"hi\""));
    }

    @Test
    void keepsEmptyFieldsAndSkipsBlankLines() {
        assertThat(read("﻿node_code,hierarchy_code,value\n\n10110,,USD\n10120,,\n\n"))
                .containsExactly(List.of("node_code", "hierarchy_code", "value"), List.of("10110", "", "USD"), List.of("10120", "", ""));
    }

    @Test
    void aQuotedFieldMaySpanLines() {
        assertThat(read("code,description\nX,\"first line\nsecond line\"\n")).containsExactly(List.of("code", "description"),
                List.of("X", "first line\nsecond line"));
    }

    @Test
    void anUnclosedQuoteIsRefused() {
        assertThatThrownBy(() -> read("a\n\"open")).isInstanceOf(IllegalArgumentException.class);
    }
}
