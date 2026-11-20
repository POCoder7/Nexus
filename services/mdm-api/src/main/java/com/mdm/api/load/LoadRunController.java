package com.mdm.api.load;

import com.mdm.api.common.Cursors;
import com.mdm.api.common.Page;
import com.mdm.api.load.HackathonIntake.LoadFinding;
import com.mdm.api.load.HackathonIntake.IntakeResult;
import com.mdm.api.load.LoadRunService.LoadRunView;
import com.mdm.api.security.Actor;
import com.mdm.api.security.EntitlementService;
import com.mdm.api.security.ForbiddenException;
import com.mdm.api.security.Permission;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RequestPart;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.util.unit.DataSize;
import org.springframework.web.multipart.MultipartFile;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/**
 * Data loads for the hackathon data set (ADR-046; Phase 4 LLD §17.8, §17.8.2): upload and check, prepare, approve by a
 * second ADMIN, apply, and the history. ADMIN only.
 */
@RestController
@RequestMapping("/api/v1/admin/load-runs")
public class LoadRunController {

    public record PrepareBody(String version) {
    }

    public record ApproveBody(String manifestSha256) {
    }

    private final HackathonIntake intake;
    private final LoadRunService runs;
    private final EntitlementService entitlements;
    private final Cursors cursors;
    private final long maxUploadBytes;

    public LoadRunController(HackathonIntake intake, LoadRunService runs, EntitlementService entitlements, Cursors cursors,
                             @Value("${spring.servlet.multipart.max-request-size:20MB}") DataSize maxUpload) {
        this.maxUploadBytes = maxUpload.toBytes();
        this.intake = intake;
        this.runs = runs;
        this.entitlements = entitlements;
        this.cursors = cursors;
    }

    /** Stages the uploaded CSV files as a new load and checks them. The response's loadId is the run's id from now on. */
    @PostMapping(value = "/uploads", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<IntakeResult> uploadLoadFiles(Actor actor, @RequestPart("files") List<MultipartFile> files) throws IOException {
        requireAdmin(actor);
        Map<String, byte[]> content = new LinkedHashMap<>();
        for (MultipartFile f : files) {
            String name = baseName(f.getOriginalFilename() == null ? f.getName() : f.getOriginalFilename());
            if (name.toLowerCase(Locale.ROOT).endsWith(".zip")) {
                unzip(f.getBytes(), content);
            } else {
                content.put(name, f.getBytes());
            }
        }
        return ResponseEntity.status(HttpStatus.CREATED).body(intake.stage(actor, UUID.randomUUID(), content));
    }

    @GetMapping("/{id}/findings")
    public List<LoadFinding> listLoadFindings(Actor actor, @PathVariable UUID id) {
        requireAdmin(actor);
        return intake.findings(id);
    }

    @PostMapping("/{id}/prepare")
    public LoadRunView prepareLoadRun(Actor actor, @PathVariable UUID id, @RequestBody(required = false) PrepareBody body) {
        requireAdmin(actor);
        return runs.prepare(actor, id, body == null ? null : body.version());
    }

    @PostMapping("/{id}/approve")
    public LoadRunView approveLoadRun(Actor actor, @PathVariable UUID id, @RequestBody ApproveBody body) {
        requireAdmin(actor);
        return runs.approve(actor, id, body.manifestSha256());
    }

    /** Applies the run as its approver. {@code wait=false} returns at once with the run applying; poll GET {id}. */
    @PostMapping("/{id}/apply")
    public LoadRunView applyLoadRun(Actor actor, @PathVariable UUID id, @RequestParam(defaultValue = "true") boolean wait) {
        requireAdmin(actor);
        return wait ? runs.apply(actor, id) : runs.applyInBackground(actor, id);
    }

    @PostMapping("/{id}/cancel")
    public LoadRunView cancelLoadRun(Actor actor, @PathVariable UUID id) {
        requireAdmin(actor);
        return runs.cancel(actor, id);
    }

    @GetMapping("/{id}")
    public LoadRunView getLoadRun(Actor actor, @PathVariable UUID id) {
        requireAdmin(actor);
        return runs.get(id);
    }

    /** Load runs, newest first, keyset-paged. */
    @GetMapping
    public Page<LoadRunView> listLoadRuns(Actor actor, @RequestParam(defaultValue = "20") int limit,
                                          @RequestParam(required = false) String cursor) {
        requireAdmin(actor);
        cursors.checkLimit(limit);
        List<String> after = cursors.decode(cursor, 1);
        return Page.of(runs.page(after == null ? null : Instant.parse(after.get(0)), limit), limit,
                r -> cursors.encode(r.preparedAt().toString()));
    }

    private static String baseName(String path) {
        return path.replaceAll(".*[/\\\\]", "");
    }

    /**
     * The CSV files of a zip, by file name (folders inside the zip are ignored). Read in memory and capped at
     * {@code LOAD_UPLOAD_MAX_BYTES} once unpacked, so a small zip cannot expand without limit.
     */
    private void unzip(byte[] zip, Map<String, byte[]> into) throws IOException {
        long total = 0;
        try (ZipInputStream in = new ZipInputStream(new ByteArrayInputStream(zip))) {
            for (ZipEntry e = in.getNextEntry(); e != null; e = in.getNextEntry()) {
                if (e.isDirectory() || !e.getName().toLowerCase(Locale.ROOT).endsWith(".csv")) {
                    continue;
                }
                ByteArrayOutputStream out = new ByteArrayOutputStream();
                byte[] buffer = new byte[8192];
                for (int n = in.read(buffer); n > 0; n = in.read(buffer)) {
                    total += n;
                    if (total > maxUploadBytes) {
                        throw new IllegalArgumentException("The zip unpacks to more than " + maxUploadBytes + " bytes");
                    }
                    out.write(buffer, 0, n);
                }
                into.put(baseName(e.getName()), out.toByteArray());
            }
        }
    }

    private void requireAdmin(Actor actor) {
        if (!entitlements.hasAny(actor, Permission.ADMIN_SYSTEM)) {
            throw new ForbiddenException("entitlement.missing", "Only an administrator can load data.");
        }
    }
}
