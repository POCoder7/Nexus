package com.mdm.api.security;

/** The actor lacks a permission for this hierarchy or node. The message says why, in words (UI_STANDARD §6). */
public class ForbiddenException extends RuntimeException {

    private final String code;

    public ForbiddenException(String code, String message) {
        super(message);
        this.code = code;
    }

    public String code() {
        return code;
    }
}
