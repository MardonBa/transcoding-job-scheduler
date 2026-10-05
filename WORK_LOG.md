# Work Log

## 10/3

Working on setting up boilerplate (frontend) and planning out exactly how the app should work. My goal for this project is to know exactly what to show the users, what the functionality will be, what the api contract will be, how users should interact, work on incorporating the UML diagrams we've learned about in class.

I'll probably describe the flows in plaintext and have claude diagram it, and also have Claude build the frontend. Backend I want to be me (?), at least the setup and getting routes set up, working with the Firecrawl API, etc. Goal is in part to learn how to use Go.

I'm also pivoting from scraping to video transcoding. Puts more work on me, CPU, etc. Better for managing queue, workers, etc. I.E. don't overuse resources.

## 10/4

I think my AI approach for this project specifically will be closer to what I do in work at Trek, which is to talk through each phase, the requirements, and decisions, and then hand off implementation. An exception to that will be implementing things I've never done before. So that means the G0 backend, SSE, redis queue, etc. So a big portion of this project will definitely get written by hand, but things like frontend, planning, etc will be done by me + AI.

Go is definitely an interesting language. I have some thoughts on how the layout of my code will be, but I want to first see what is considered idiomatic.