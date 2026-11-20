package com.mdm.api.load;

import com.mdm.api.PostgresIntegrationTest;
import com.mdm.api.load.HackathonIntake.IntakeResult;
import com.mdm.api.load.HackathonIntake.StagedFile;
import com.mdm.api.security.Actor;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Staging and profiling the hackathon data set (ADR-046, Phase 4 LLD §17.1, increment H-5) with the synthetic sample in
 * src/test/resources/load/hackathon (a copy of the git-ignored data/ folder). The API stages through the loader's
 * functions only.
 */
class HackathonIntakeTest extends PostgresIntegrationTest {

    static final String[] FILES = {"attribute_definitions.csv", "attribute_values.csv", "groups.csv", "hierarchies.csv", "ledgers.csv",
            "nodes.csv", "reference_lists.csv", "relationships.csv", "roles.csv", "users.csv", "validation_rules.csv", "versions.csv"};

    @Autowired
    HackathonIntake intake;

    private Actor admin() {
        UUID id = ensureUser("hx_admin", "human");
        return new Actor(id, "hx_admin", "Intake admin", "human");
    }

    private static Map<String, byte[]> sample() throws IOException {
        Map<String, byte[]> files = new HashMap<>();
        for (String f : FILES) {
            try (InputStream in = HackathonIntakeTest.class.getResourceAsStream("/load/hackathon/" + f)) {
                files.put(f, in.readAllBytes());
            }
        }
        return files;
    }

    @Test
    void theSampleStagesCleanlyFileByFile() throws Exception {
        IntakeResult r = intake.stage(admin(), UUID.randomUUID(), sample());
        assertThat(r.rejected()).isEmpty();
        assertThat(r.errors()).as("errors: %s", r.findings()).isZero();
        Map<String, Integer> rows = r.staged().stream().collect(Collectors.toMap(StagedFile::fileName, StagedFile::rows));
        assertThat(rows).containsEntry("hierarchies.csv", 3).containsEntry("nodes.csv", 59).containsEntry("relationships.csv", 94)
                .containsEntry("attribute_definitions.csv", 18).containsEntry("attribute_values.csv", 184)
                .containsEntry("reference_lists.csv", 20).containsEntry("ledgers.csv", 3).containsEntry("validation_rules.csv", 18)
                .containsEntry("versions.csv", 4).containsEntry("users.csv", 11).containsEntry("groups.csv", 6).containsEntry("roles.csv", 5);
        // what the load will leave out is said up front: four derived attributes and the FEED rule
        assertThat(r.findings()).filteredOn(f -> "skipped".equals(f.kind())).hasSize(5);
    }

    @Test
    void aWrongHeaderOrAnUnknownFileIsRejectedAndTheRestIsStillStaged() throws Exception {
        Map<String, byte[]> files = sample();
        files.put("ledgers.csv", "ledger_id,ledger_name,currency,chart_of_accounts\nL1,One,USD,X\n".getBytes(StandardCharsets.UTF_8));
        files.put("accounts.csv", "a,b\n1,2\n".getBytes(StandardCharsets.UTF_8));
        IntakeResult r = intake.stage(admin(), UUID.randomUUID(), files);
        assertThat(r.rejected()).extracting(HackathonIntake.RejectedFile::fileName).containsExactlyInAnyOrder("ledgers.csv", "accounts.csv");
        assertThat(r.rejected()).filteredOn(x -> x.fileName().equals("ledgers.csv")).first()
                .satisfies(x -> assertThat(x.reason()).contains("ledger_id,ledger_name,currency,finance_country"));
        assertThat(r.staged()).hasSize(11);
    }

    @Test
    void aBrokenRowIsReportedWithItsLineAndBlocksTheLoad() throws Exception {
        Map<String, byte[]> files = sample();
        String nodes = new String(files.get("nodes.csv"), StandardCharsets.UTF_8) + "99999,Broken row,LEAF\n";
        files.put("nodes.csv", nodes.getBytes(StandardCharsets.UTF_8));
        IntakeResult r = intake.stage(admin(), UUID.randomUUID(), files);
        assertThat(r.errors()).isEqualTo(1);
        assertThat(r.findings()).filteredOn(f -> "error".equals(f.severity())).singleElement()
                .satisfies(f -> {
                    assertThat(f.fileName()).isEqualTo("nodes.csv");
                    assertThat(f.kind()).isEqualTo("row_width");
                    assertThat(f.lineNo()).isEqualTo(61);   // header, 59 nodes, then this row
                });
    }
}
