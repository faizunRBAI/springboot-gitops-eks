package com.example.springbootgitopseks;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Exposes the identity of the running instance.
 *
 * <p>During a blue/green cutover or a canary rollout several revisions of this
 * application serve traffic at the same time. Reporting the image tag and the
 * pod name makes it possible to observe which revision answered a request,
 * which is what turns a progressive rollout from a leap of faith into
 * something you can watch.
 */
@RestController
@RequestMapping("/api")
public class InfoController {

    private final String appVersion;
    private final String imageTag;
    private final String podName;
    private final Instant startedAt = Instant.now();

    public InfoController(
            @Value("${app.version:dev}") String appVersion,
            @Value("${app.image-tag:local}") String imageTag,
            @Value("${app.pod-name:local}") String podName) {
        this.appVersion = appVersion;
        this.imageTag = imageTag;
        this.podName = podName;
    }

    @GetMapping(value = "/info", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, Object> info() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("application", "springboot-gitops-eks");
        body.put("version", appVersion);
        body.put("imageTag", imageTag);
        body.put("podName", podName);
        body.put("startedAt", startedAt.toString());
        body.put("uptimeSeconds", java.time.Duration.between(startedAt, Instant.now()).toSeconds());
        return body;
    }
}
