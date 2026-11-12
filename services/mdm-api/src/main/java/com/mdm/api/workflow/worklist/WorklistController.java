package com.mdm.api.workflow.worklist;

import com.mdm.api.security.Actor;
import com.mdm.api.workflow.worklist.WorklistQuery.WorklistPage;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * GOV-13 worklist (Phase 2 LLD §4.9, §5.1): the nine DRG views with a count per view, search, a model filter and keyset
 * paging. Rows are filtered in SQL ({@link WorklistQuery}). {@code notified} is always empty until notifications (GOV-08)
 * are decided.
 */
@RestController
@RequestMapping("/api/v1/worklist")
public class WorklistController {

    private final WorklistQuery query;

    public WorklistController(WorklistQuery query) {
        this.query = query;
    }

    @GetMapping
    public WorklistPage getWorklist(Actor actor,
                                    @RequestParam(defaultValue = "assigned") String view,
                                    @RequestParam(required = false) String search,
                                    @RequestParam(required = false) String model,
                                    @RequestParam(defaultValue = "50") int limit,
                                    @RequestParam(required = false) String cursor) {
        return query.page(actor, view, search, model, limit, cursor);
    }
}
