# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActivityPub::Activity::Delete do
  let(:sender) { Fabricate(:account, domain: 'example.com') }
  let(:status) { Fabricate(:status, account: sender, uri: 'foobar') }

  let(:json) do
    {
      '@context': 'https://www.w3.org/ns/activitystreams',
      id: 'foo',
      type: 'Delete',
      actor: ActivityPub::TagManager.instance.uri_for(sender),
      object: ActivityPub::TagManager.instance.uri_for(status),
      signature: 'foo',
    }.with_indifferent_access
  end

  describe '#perform' do
    subject { described_class.new(json, sender) }

    before do
      subject.perform
    end

    it 'deletes sender\'s status' do
      expect(Status.find_by(id: status.id)).to be_nil
    end
  end

  context 'when the status has been reblogged' do
    describe '#perform' do
      subject { described_class.new(json, sender) }

      let!(:reblogger) { Fabricate(:account) }
      let!(:follower)  { Fabricate(:account, username: 'follower', protocol: :activitypub, domain: 'example.com', inbox_url: 'http://example.com/inbox') }
      let!(:reblog)    { Fabricate(:status, account: reblogger, reblog: status) }

      before do
        stub_request(:post, 'http://example.com/inbox').to_return(status: 200)
        follower.follow!(reblogger)
        subject.perform
      end

      it 'deletes sender\'s status' do
        expect(Status.find_by(id: status.id)).to be_nil
      end

      it 'sends delete activity to followers of rebloggers', :inline_jobs do
        expect(a_request(:post, 'http://example.com/inbox')).to have_been_made.once
      end

      it 'deletes the reblog' do
        expect { reblog.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  context 'when the status has been reported' do
    describe '#perform' do
      subject { described_class.new(json, sender) }

      let!(:reporter) { Fabricate(:account) }

      before do
        reporter.reports.create!(target_account: status.account, status_ids: [status.id], forwarded: false)
        subject.perform
      end

      it 'marks the status as deleted' do
        expect(Status.find_by(id: status.id)).to be_nil
      end

      it 'actually keeps a copy for inspection' do
        expect(Status.with_discarded.find_by(id: status.id)).to_not be_nil
      end
    end
  end

  context 'when the deleted object is an account' do
    let(:json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'foo',
        type: 'Delete',
        actor: ActivityPub::TagManager.instance.uri_for(sender),
        object: ActivityPub::TagManager.instance.uri_for(sender),
        signature: 'foo',
      }.with_indifferent_access
    end

    describe '#perform' do
      subject { described_class.new(json, sender) }

      let(:service) { instance_double(DeleteAccountService, call: true) }

      before do
        allow(DeleteAccountService).to receive(:new).and_return(service)
      end

      it 'calls the account deletion service' do
        subject.perform

        expect(service)
          .to have_received(:call).with(sender, { reserve_username: false, skip_activitypub: true })
      end
    end
  end

  context 'when the deleted object is a quote authorization' do
    let(:quoter) { Fabricate(:account, domain: 'b.example.com') }
    let(:status) { Fabricate(:status, account: quoter) }
    let(:quoted_status) { Fabricate(:status, account: sender, uri: 'https://example.com/statuses/1234') }
    let!(:quote) { Fabricate(:quote, approval_uri: 'https://example.com/approvals/1234', state: :accepted, status: status, quoted_status: quoted_status) }

    let(:json) do
      {
        '@context': 'https://www.w3.org/ns/activitystreams',
        id: 'foo',
        type: 'Delete',
        actor: ActivityPub::TagManager.instance.uri_for(sender),
        object: quote.approval_uri,
        signature: 'foo',
      }.with_indifferent_access
    end

    describe '#perform' do
      subject { described_class.new(json, sender) }

      it 'revokes the authorization' do
        expect { subject.perform }
          .to change { quote.reload.state }.to('revoked')
      end
    end
  end
end
