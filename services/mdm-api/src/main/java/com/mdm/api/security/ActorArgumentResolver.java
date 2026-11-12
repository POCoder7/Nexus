package com.mdm.api.security;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.core.MethodParameter;
import org.springframework.stereotype.Component;
import org.springframework.web.bind.support.WebDataBinderFactory;
import org.springframework.web.context.request.NativeWebRequest;
import org.springframework.web.method.support.HandlerMethodArgumentResolver;
import org.springframework.web.method.support.ModelAndViewContainer;

/** Lets controller methods declare an {@link Actor} parameter; the value comes from {@link ActorFilter}. */
@Component
public class ActorArgumentResolver implements HandlerMethodArgumentResolver {

    @Override
    public boolean supportsParameter(MethodParameter parameter) {
        return Actor.class.equals(parameter.getParameterType());
    }

    @Override
    public Object resolveArgument(MethodParameter parameter, ModelAndViewContainer mav, NativeWebRequest webRequest,
                                  WebDataBinderFactory binderFactory) {
        Object actor = webRequest.getNativeRequest(HttpServletRequest.class).getAttribute(ActorFilter.ATTRIBUTE);
        if (actor == null) {
            // ActorFilter guarantees an actor for /api/**; reaching here means a mapping outside it asked for one.
            throw new IllegalStateException("No actor on this request");
        }
        return actor;
    }
}
