package com.mdm.api.common;

/** A business rule checked in the API refused the request (422, with a machine code like the database guards). */
public class RuleException extends RuntimeException {

    private final String code;

    public RuleException(String code, String message) {
        super(message);
        this.code = code;
    }

    public String code() {
        return code;
    }
}
