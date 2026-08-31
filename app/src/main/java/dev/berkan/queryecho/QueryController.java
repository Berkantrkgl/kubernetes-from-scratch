package dev.berkan.queryecho;

import java.util.Map;
import java.util.stream.Collectors;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class QueryController {

	private static final Logger log = LoggerFactory.getLogger(QueryController.class);

	private final String instance;

	QueryController(@Value("${app.instance}") String instance) {
		this.instance = instance;
	}

	// slf4j rather than System.out, otherwise the line bypasses logback and cannot
	// be routed to the async file appender
	@GetMapping("/api/foos")
	public String foos(@RequestParam Map<String, String> params) {
		String rendered = params.isEmpty()
				? "(none)"
				: params.entrySet().stream()
						.map(e -> e.getKey() + "=" + e.getValue())
						.collect(Collectors.joining(", "));

		log.info("QueryStringValue: {}", rendered);
		return "QueryStringValue: " + rendered + "   [" + instance + "]\n";
	}
}
