package com.mdm.api.workflow.engine.camunda;

import io.camunda.zeebe.spring.client.configuration.CamundaAutoConfiguration;
import org.springframework.boot.autoconfigure.ImportAutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Configuration;

/**
 * Turns the Camunda client on only when {@code mdm.workflow.engine=camunda} (ADR-035). The SDK's auto-configuration is
 * excluded in application.yml, so the API and every process using the in-process driver run without a Camunda client.
 * Connection settings are the SDK's own {@code camunda.client.*} properties (self-managed or SaaS, OD-01c).
 */
@Configuration
@ConditionalOnProperty(name = "mdm.workflow.engine", havingValue = "camunda")
@ImportAutoConfiguration(CamundaAutoConfiguration.class)
public class CamundaEngineConfiguration {
}
