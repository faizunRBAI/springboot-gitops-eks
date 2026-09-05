package com.example.springbootgitopseks;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.forwardedUrl;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest
@AutoConfigureMockMvc
@TestPropertySource(properties = {
        "app.version=1.2.3",
        "app.image-tag=testtag",
        "app.pod-name=test-pod-0",
        "management.endpoints.web.exposure.include=health,info,prometheus"
})
class SpringbootGitopsEksApplicationTests {

    @Autowired
    private MockMvc mockMvc;

    @Test
    @DisplayName("application context loads")
    void contextLoads() {
        // Fails on any misconfigured bean, missing property or broken autoconfiguration.
    }

    @Test
    @DisplayName("/ forwards to the static landing page")
    void rootForwardsToLandingPage() throws Exception {
        // Spring Boot maps "/" to the welcome page via a ParameterizableViewController
        // that FORWARDS to index.html. MockMvc does not execute forwards, so the
        // response body and content type are empty here by design — the forward
        // target is the assertable behaviour.
        mockMvc.perform(get("/"))
                .andExpect(status().isOk())
                .andExpect(forwardedUrl("index.html"));
    }

    @Test
    @DisplayName("landing page is served as HTML with the expected content")
    void landingPageIsServedAsHtml() throws Exception {
        // Requested directly, index.html is served by the static resource handler
        // (not a forward), so the real content type and body are observable.
        mockMvc.perform(get("/index.html"))
                .andExpect(status().isOk())
                .andExpect(content().contentTypeCompatibleWith("text/html"))
                .andExpect(content().string(
                        org.hamcrest.Matchers.containsString("springboot-gitops-eks")));
    }

    @Test
    @DisplayName("/api/info reports version, image tag and pod identity")
    void infoEndpointReportsIdentity() throws Exception {
        mockMvc.perform(get("/api/info"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.application").value("springboot-gitops-eks"))
                .andExpect(jsonPath("$.version").value("1.2.3"))
                .andExpect(jsonPath("$.imageTag").value("testtag"))
                .andExpect(jsonPath("$.podName").value("test-pod-0"))
                .andExpect(jsonPath("$.uptimeSeconds").isNumber());
    }

    @Test
    @DisplayName("/actuator/health reports UP for kubelet probes")
    void healthEndpointIsUp() throws Exception {
        mockMvc.perform(get("/actuator/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"));
    }

    @Test
    @DisplayName("liveness and readiness probe groups are available")
    void probeGroupsAreExposed() throws Exception {
        mockMvc.perform(get("/actuator/health/liveness"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"));
        mockMvc.perform(get("/actuator/health/readiness"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"));
    }

    @Test
    @DisplayName("/actuator/prometheus exposes http_server_requests metrics for canary analysis")
    void prometheusEndpointExposesMetrics() throws Exception {
        // Generate at least one request so the http.server.requests meter exists.
        mockMvc.perform(get("/api/info")).andExpect(status().isOk());

        mockMvc.perform(get("/actuator/prometheus"))
                .andExpect(status().isOk())
                .andExpect(content().string(
                        org.hamcrest.Matchers.containsString("http_server_requests_seconds")))
                .andExpect(content().string(
                        org.hamcrest.Matchers.containsString("application=\"springboot-gitops-eks\"")));
    }
}
