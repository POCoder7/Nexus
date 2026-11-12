package com.mdm.api.workflow.engine;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-035: Camunda stays replaceable only if nothing outside its adapter depends on it. No production class outside
 * {@code com.mdm.api.workflow.engine.camunda} may import a Camunda type.
 */
class EngineBoundaryTest {

    @Test
    void onlyTheCamundaAdapterImportsCamunda() throws IOException {
        Path main = Path.of("src", "main", "java");
        Path adapter = main.resolve(Path.of("com", "mdm", "api", "workflow", "engine", "camunda"));
        List<Path> offenders;
        try (Stream<Path> files = Files.walk(main)) {
            offenders = files.filter(p -> p.toString().endsWith(".java"))
                    .filter(p -> !p.startsWith(adapter))
                    .filter(p -> {
                        try {
                            return Files.readString(p).contains("io.camunda");
                        } catch (IOException e) {
                            throw new IllegalStateException(e);
                        }
                    })
                    .toList();
        }
        assertThat(offenders).as("classes outside the Camunda adapter that reference io.camunda").isEmpty();
    }
}
