export default Discourse.Route.extend({
  model() {
    return this.store.findAll("reviewable-topic");
  },

  setupController(controller, model) {
    controller.setProperties({
      reviewableTopics: model
    });
  }
});
