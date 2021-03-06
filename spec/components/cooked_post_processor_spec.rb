require 'spec_helper'

require 'cooked_post_processor'

describe CookedPostProcessor do

  def cpp(cooked = nil, options = {})
    post = Fabricate.build(:post_with_youtube)
    post.cooked = cooked if cooked
    post.id = 123
    CookedPostProcessor.new(post, options)
  end

  context 'process_onebox' do

    before do
      @cpp = cpp(nil, invalidate_oneboxes: true)
      Oneboxer.expects(:onebox).with("http://www.youtube.com/watch?v=9bZkp7q19f0", post_id: 123, invalidate_oneboxes: true).returns('<div>GANGNAM STYLE</div>')
      @cpp.post_process_oneboxes
    end

    it 'should be dirty' do
      @cpp.should be_dirty
    end

    it 'inserts the onebox without wrapping p' do
      @cpp.html.should match_html "<div>GANGNAM STYLE</div>"
    end

  end


  context 'process_images' do

    it "has no topic image if there isn't one in the post" do
      @post = Fabricate(:post)
      @post.topic.image_url.should be_blank
    end

    context 'with sized images in the post' do
      before do
        @topic = Fabricate(:topic)
        @post = Fabricate.build(:post_with_image_url, topic: @topic, user: @topic.user)
        @cpp = CookedPostProcessor.new(@post, image_sizes: {'http://www.forumwarz.com/images/header/logo.png' => {'width' => 111, 'height' => 222}})
        @cpp.expects(:get_size).returns([111,222])
      end

      it "doesn't call image_dimensions because it knows the size" do
        @cpp.expects(:image_dimensions).never
        @cpp.post_process_images
      end

      it "adds the width from the image sizes provided" do
        @cpp.post_process_images
        @cpp.html.should =~ /width=\"111\"/
      end

    end

    context 'with uploaded images in the post' do
      before do
        @topic = Fabricate(:topic)
        @post = Fabricate(:post_with_uploads, topic: @topic, user: @topic.user)
        @cpp = CookedPostProcessor.new(@post)
        @cpp.expects(:get_upload_from_url).returns(Fabricate(:upload))
        @cpp.expects(:get_size).returns([100,200])
      end

      it "keeps reverse index up to date" do
        @cpp.post_process_images
        @post.uploads.reload
        @post.uploads.count.should == 1
      end

    end

    context 'with unsized images in the post' do
      let(:user) { Fabricate(:user) }
      let(:topic) { Fabricate(:topic, user: user) }

      before do
        FastImage.stubs(:size).returns([123, 456])
        creator = PostCreator.new(user, raw: Fabricate.build(:post_with_images).raw, topic_id: topic.id)
        @post = creator.create
      end

      it "adds a topic image if there's one in the post" do
        @post.topic.reload
        @post.topic.image_url.should == "http://test.localhost/path/to/img.jpg"
      end

      it "adds the height and width to images that don't have them" do
        @post.reload
        @post.cooked.should =~ /width=\"123\" height=\"456\"/
      end

    end

    context 'with an absolute image path without protocol' do
      let(:user) { Fabricate(:user) }
      let(:topic) { Fabricate(:topic, user: user) }
      let(:post) { Fabricate.build(:post_with_s3_image_url, topic: topic, user: user) }
      let(:processor) { CookedPostProcessor.new(post) }

      before do
        processor.post_process_images
      end

      it "doesn't change the protocol" do
        processor.html.should =~ /src="\/\/bucket\.s3\.amazonaws\.com\/uploads\/6\/4\/123\.png"/
      end
    end

    context 'with a oneboxed image' do
      let(:user) { Fabricate(:user) }
      let(:topic) { Fabricate(:topic, user: user) }
      let(:post) { Fabricate.build(:post_with_oneboxed_image, topic: topic, user: user) }
      let(:processor) { CookedPostProcessor.new(post) }

      before do
        processor.post_process_images
      end

      it "doesn't lightbox" do
        processor.html.should_not =~ /class="lightbox"/
      end
    end

    context "with a large image" do

      let(:user) { Fabricate(:user) }
      let(:topic) { Fabricate(:topic, user: user) }
      let(:post) { Fabricate.build(:post_with_uploads, topic: topic, user: user) }
      let(:processor) { CookedPostProcessor.new(post) }

      before do
        FastImage.stubs(:size).returns([1000, 1000])
        processor.post_process_images
      end

      it "generates overlay information" do
        processor.html.should =~ /class="lightbox"/
        processor.html.should =~ /class="meta"/
        processor.html.should =~ /class="filename"/
        processor.html.should =~ /class="informations"/
        processor.html.should =~ /class="expand"/
      end

    end

  end

  context 'link convertor' do
    before do
      SiteSetting.stubs(:crawl_images?).returns(true)
    end

    let :post_with_img do
      Fabricate.build(:post, cooked: '<p><img src="http://hello.com/image.png"></p>')
    end

    let :cpp_for_post do
      CookedPostProcessor.new(post_with_img)
    end

    it 'convert img tags to links if they are sized down' do
      cpp_for_post.expects(:get_size).returns([2000,2000]).twice
      cpp_for_post.post_process
      cpp_for_post.html.should =~ /a href/
    end

    it 'does not convert img tags to links if they are small' do
      cpp_for_post.expects(:get_size).returns([200,200]).twice
      cpp_for_post.post_process
      (cpp_for_post.html !~ /a href/).should be_true
    end

  end

  context 'image_dimensions' do
    it "returns unless called with a http or https url" do
      cpp.image_dimensions('/tmp/image.jpg').should be_blank
    end

    context 'with valid url' do
      before do
        @url = 'http://www.forumwarz.com/images/header/logo.png'
      end

      it "doesn't call fastimage if image crawling is disabled" do
        SiteSetting.expects(:crawl_images?).returns(false)
        FastImage.expects(:size).never
        cpp.image_dimensions(@url)
      end

      it "calls fastimage if image crawling is enabled" do
        SiteSetting.expects(:crawl_images?).returns(true)
        FastImage.expects(:size).with(@url)
        cpp.image_dimensions(@url)
      end
    end
  end

  context 'is_valid_image_uri?' do

    it "needs the scheme to be either http or https" do
      cpp.is_valid_image_uri?("http://domain.com").should   == true
      cpp.is_valid_image_uri?("https://domain.com").should  == true
      cpp.is_valid_image_uri?("ftp://domain.com").should    == false
      cpp.is_valid_image_uri?("ftps://domain.com").should   == false
      cpp.is_valid_image_uri?("//domain.com").should        == false
      cpp.is_valid_image_uri?("/tmp/image.png").should      == false
    end

    it "doesn't throw exception with a bad URI" do
      cpp.is_valid_image_uri?("http://do<main.com").should  == nil
    end

  end

  context 'get_filename' do

    it "returns the filename of the src when there is no upload" do
      cpp.get_filename(nil, "http://domain.com/image.png").should == "image.png"
    end

    it "returns the original filename of the upload when there is an upload" do
      upload = Fabricate.build(:upload, { original_filename: "upload.jpg" })
      cpp.get_filename(upload, "http://domain.com/image.png").should == "upload.jpg"
    end

    it "returns a generic name for pasted images" do
      upload = Fabricate.build(:upload, { original_filename: "blob" })
      cpp.get_filename(upload, "http://domain.com/image.png").should == I18n.t('upload.pasted_image_filename')
    end

  end

end
