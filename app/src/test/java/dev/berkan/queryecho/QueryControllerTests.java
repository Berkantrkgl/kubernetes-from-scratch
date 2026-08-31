package dev.berkan.queryecho;

import static org.hamcrest.Matchers.containsString;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(QueryController.class)
class QueryControllerTests {

	@Autowired
	private MockMvc mockMvc;

	@Test
	void echoesEveryQueryParameter() throws Exception {
		mockMvc.perform(get("/api/foos?val=TEST&other=2"))
				.andExpect(status().isOk())
				.andExpect(content().string(containsString("val=TEST")))
				.andExpect(content().string(containsString("other=2")));
	}

	// the sample app declares val as required and answers 400 without it
	@Test
	void answersWithoutParameters() throws Exception {
		mockMvc.perform(get("/api/foos"))
				.andExpect(status().isOk());
	}
}
